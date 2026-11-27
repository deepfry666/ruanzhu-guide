import Foundation

// MARK: - 一屏的生成任务

final class Attempt: @unchecked Sendable {
    let attemptId = randomHex(6)
    let provider: ImageProvider
    let role: String
    var task: Task<Void, Never>?
    var timers: [Task<Void, Never>] = []
    var taskId: String?
    var holdsGlobal = false
    var holdsProvider = false
    var startedAt: Double?
    var sizeSpec: SizeSpec?
    var abortReason: String?
    var cancelRequested = false

    init(provider: ImageProvider, role: String) {
        self.provider = provider
        self.role = role
    }

    func abort() {
        cancelRequested = true
        task?.cancel()
    }
}

actor GatewayJob {
    let gateway: ImageGateway
    let request: GenerateRequest
    let settings: Settings
    let providers: [ImageProvider]
    let jobId: String
    let maxAttempts: Int
    let secretValues: [String]

    var settled = false
    var active: [String: Attempt] = [:]
    var activeOrder: [String] = []
    var background: [String: Attempt] = [:]
    var tried: [String] = []
    var failures: [(providerId: String, providerName: String, kind: String, message: String)] = []
    var started = 0
    var hedged = false
    var retried = Set<String>()
    var sizeOverrides: [String: SizeSpec] = [:]
    let startedAt: Double
    var continuation: CheckedContinuation<GenerateResult, Error>?
    var pendingOutcome: Result<GenerateResult, Error>?

    var imageSettings: ImageSettings { settings.image }
    var hedge: HedgeSettings { settings.image.hedge }

    init(gateway: ImageGateway, request: GenerateRequest) async throws {
        self.gateway = gateway
        self.request = request
        let settings = try await gateway.getSettings()
        self.settings = settings
        // 0 表示不限（只受每条线路自己的并发上限约束）
        gateway.globalSemaphore.setLimit(settings.image.globalConcurrency <= 0 ? Int.max : settings.image.globalConcurrency)
        providers = settings.providers.filter(\.enabled)
        if providers.isEmpty { throw StudioError("还没有可用的生图线路，请先到「生图线路」里添加并启用") }
        maxAttempts = settings.image.maxAttemptsPerScreen == 0 ? 4 : settings.image.maxAttemptsPerScreen
        secretValues = await gateway.secretList()
        jobId = "\(Path.basename(request.projectDir)):\(request.screenId):\(randomHex(4))"
        startedAt = gateway.now()
        var newJob = ImageJob(.emptyObject)
        newJob.jobId = jobId
        newJob.projectDir = request.projectDir
        newJob.screenId = request.screenId
        newJob.outputPath = request.outputPath
        newJob.alternatesDir = request.alternatesDir
        newJob.archiveRoot = request.archiveRoot
        newJob.prompt = request.prompt
        if let batchId = request.batchId { newJob.batchId = batchId } else { newJob.raw["batchId"] = .null }
        await gateway.ledger.createJob(newJob)
    }

    func run() async throws -> GenerateResult {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingOutcome {
                continuation.resume(with: pendingOutcome)
                return
            }
            self.continuation = continuation
            failover()
        }
    }

    func finish(_ outcome: Result<GenerateResult, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        } else if pendingOutcome == nil {
            pendingOutcome = outcome
        }
    }

    func emit(_ event: JSON) {
        gateway.onEvent(JSON.obj(["jobId": .string(jobId), "projectDir": .string(request.projectDir), "screenId": .string(request.screenId)]).merging(event))
    }

    func nextProvider() -> ImageProvider? {
        let candidates = providers.filter { !tried.contains($0.id) && gateway.health.unavailableReason($0.id) == nil }
        guard let first = candidates.first else { return nil }
        // 首选线路满载时，分流到同画风组里还有空位的线路（不改变画风）
        if imageSettings.spillover, !gateway.providerSemaphore(first).hasCapacity() {
            let group = modelGroupOf(first)
            if let spare = candidates.first(where: { $0.id != first.id && modelGroupOf($0) == group && gateway.providerSemaphore($0).hasCapacity() }) { return spare }
        }
        return first
    }

    func unavailableSummary() -> [String] {
        providers.compactMap { provider in gateway.health.unavailableReason(provider.id).map { "\(provider.name)：\($0)" } }
    }

    func abortAll() async {
        if settled { return }
        settled = true
        for attempt in Array(active.values) + Array(background.values) {
            attempt.abortReason = "canceled"
            attempt.abort()
        }
        var patch = ImageJob(.emptyObject)
        patch.state = "canceled"
        await gateway.ledger.finishJob(jobId, patch)
        finish(.failure(ProviderError("已取消", kind: "aborted")))
    }

    func failJob(_ extraMessage: String) {
        if settled { return }
        settled = true
        for attempt in Array(active.values) + Array(background.values) {
            attempt.abortReason = "job-failed"
            attempt.abort()
        }
        let lines = failures.map { "\($0.providerName)：\($0.message)" }
        let unavailable = unavailableSummary()
        let message = ([extraMessage] + lines + (unavailable.isEmpty ? [] : ["不可用的线路："] + unavailable)).filter { !$0.isEmpty }.joined(separator: "\n")
        Task {
            var patch = ImageJob(.emptyObject)
            patch.state = "failed"
            patch.error = message
            await gateway.ledger.finishJob(jobId, patch)
            emit(.obj(["type": "job-failed", "message": .string(message)]))
            finish(.failure(GenerateFailure(message: message.isEmpty ? "生图失败" : message)))
        }
    }

    func failover() {
        if settled { return }
        if !active.isEmpty || !background.isEmpty { return }
        if started >= maxAttempts {
            failJob("已尝试 \(started) 次，仍未成功")
            return
        }
        guard let next = nextProvider() else {
            failJob(tried.isEmpty ? "没有可用的生图线路" : "所有可用线路都试过了")
            return
        }
        launch(next, role: tried.isEmpty ? "primary" : "failover")
    }

    func launch(_ provider: ImageProvider, role: String) {
        if settled { return }
        let attempt = Attempt(provider: provider, role: role)
        active[attempt.attemptId] = attempt
        activeOrder.append(attempt.attemptId)
        tried.append(provider.id)
        started += 1
        attempt.task = Task { await self.execute(attempt) }
    }

    func execute(_ attempt: Attempt) async {
        let provider = attempt.provider
        do {
            // 先等线路名额再占全局名额：排队等某条线路的任务不占全局名额，补发和分流不会被堵住
            try await gateway.providerSemaphore(provider).acquire()
            attempt.holdsProvider = true
            try await gateway.globalSemaphore.acquire()
            attempt.holdsGlobal = true
        } catch {
            releaseSlots(attempt)
            await handleFailure(attempt, error)
            return
        }
        if settled {
            releaseSlots(attempt)
            removeActive(attempt)
            return
        }
        attempt.startedAt = gateway.now()
        let sizeSpec = sizeOverrides[provider.id] ?? resolveRequestSize(provider, imageSettings.targetSize)
        attempt.sizeSpec = sizeSpec
        var startedAttempt = ImageAttempt(.emptyObject)
        startedAttempt.attemptId = attempt.attemptId
        startedAttempt.providerId = provider.id
        startedAttempt.model = provider.model
        startedAttempt.role = attempt.role
        startedAttempt.requestSize = sizeSpec.size
        await gateway.ledger.startAttempt(jobId, startedAttempt)
        emit(.obj(["type": "attempt-start", "providerId": .string(provider.id), "providerName": .string(provider.name), "role": .string(attempt.role), "requestSize": .string(sizeSpec.size)]))
        let apiKey = await gateway.secrets.get(SecretIds.imageProvider(provider.id))
        if settled {
            releaseSlots(attempt)
            removeActive(attempt)
            var aborted = ImageAttempt(.emptyObject)
            aborted.state = "aborted"
            aborted.outcome = "not-needed"
            await gateway.ledger.finishAttempt(jobId, attempt.attemptId, aborted)
            return
        }
        if apiKey.isEmpty {
            releaseSlots(attempt)
            await handleFailure(attempt, ProviderError("这条线路还没有填写密钥", kind: "auth"))
            return
        }
        if attempt.cancelRequested {
            releaseSlots(attempt)
            await handleFailure(attempt, ProviderError.aborted())
            return
        }
        if attempt.role != "hedge", hedge.enabled, hedge.maxPerBatch != 0 {
            let delay = gateway.hedgeThresholdMs(provider, hedge)
            attempt.timers.append(Task {
                guard (try? await sleepMs(delay)) != nil else { return }
                await self.onHedgeTimer(attempt)
            })
        }
        let hardMs = (provider.hardTimeoutSec == 0 ? 240 : provider.hardTimeoutSec) * 1000
        attempt.timers.append(Task {
            guard (try? await sleepMs(hardMs)) != nil else { return }
            await self.onHardTimeout(attempt)
        })
        let jobId = self.jobId
        let ledger = gateway.ledger
        do {
            let result = try await runAttempt(
                provider: provider, apiKey: apiKey, prompt: request.prompt, size: sizeSpec.size, quality: imageSettings.quality,
                onTaskId: { taskId in
                    await self.setTaskId(attempt, taskId)
                    await ledger.markTaskId(jobId, attempt.attemptId, taskId)
                    await self.emit(.obj(["type": "attempt-task", "providerId": .string(provider.id), "taskId": .string(taskId)]))
                },
                http: gateway.http
            )
            await handleSuccess(attempt, result)
        } catch {
            await handleFailure(attempt, error)
        }
    }

    func setTaskId(_ attempt: Attempt, _ taskId: String) { attempt.taskId = taskId }

    func removeActive(_ attempt: Attempt) {
        active[attempt.attemptId] = nil
        activeOrder.removeAll { $0 == attempt.attemptId }
    }

    func releaseSlots(_ attempt: Attempt) {
        if attempt.holdsGlobal {
            attempt.holdsGlobal = false
            gateway.globalSemaphore.release()
        }
        if attempt.holdsProvider {
            attempt.holdsProvider = false
            gateway.providerSemaphore(attempt.provider).release()
        }
    }

    func clearTimers(_ attempt: Attempt) {
        attempt.timers.forEach { $0.cancel() }
        attempt.timers = []
    }

    func logCall(_ attempt: Attempt, _ fields: JSON) async {
        let durationMs = attempt.startedAt.map { gateway.now() - $0 } ?? 0
        let base = JSON.obj([
            "jobId": .string(jobId), "projectDir": .string(request.projectDir), "projectName": .string(request.projectName), "screenId": .string(request.screenId),
            "providerId": .string(attempt.provider.id), "providerName": .string(attempt.provider.name), "model": .string(attempt.provider.model),
            "role": .string(attempt.role), "requestSize": JSON.maybe(attempt.sizeSpec?.size), "taskId": JSON.maybe(attempt.taskId),
            "durationMs": .number(durationMs),
        ])
        await gateway.callLog.append(base.merging(fields))
    }
}
