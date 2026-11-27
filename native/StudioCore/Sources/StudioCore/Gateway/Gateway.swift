import Foundation

let PROBE_PROMPT = "A single portrait mobile app settings screen, light theme, clean list of toggles and section headers in Simplified Chinese. No logo, no brand name, no device frame."

public struct GenerateRequest: Sendable {
    public var projectDir: String
    public var projectName: String
    public var screenId: String
    public var prompt: String
    public var outputPath: String
    public var alternatesDir: String
    public var archiveRoot: String
    public var batchId: String?

    public init(projectDir: String, projectName: String, screenId: String, prompt: String, outputPath: String, alternatesDir: String, archiveRoot: String, batchId: String? = nil) {
        self.projectDir = projectDir
        self.projectName = projectName
        self.screenId = screenId
        self.prompt = prompt
        self.outputPath = outputPath
        self.alternatesDir = alternatesDir
        self.archiveRoot = archiveRoot
        self.batchId = batchId
    }
}

public struct GenerateResult: Sendable {
    public var jobId: String
    public var outputPath: String
    public var providerId: String
    public var providerName: String
    public var model: String
    public var requestSize: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Double
    public var hedged: Bool
    public var attempts: Int
    public var warnings: [String]
    public var resumed = false
    public var ok = true
}

/// 整屏失败：message 里列出每条线路的原因。
public struct GenerateFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// 生图网关：每屏一个独立任务，真正异步并发；失败切换、超时补发、额度冷却、任务账本续查。
public actor ImageGateway {
    let getSettings: @Sendable () async throws -> Settings
    let updateProvider: @Sendable (String, SizeFallback) async -> Void
    let secrets: SecretStore
    let ledger: Ledger
    let health: HealthStore
    let callLog: CallLog
    let http: HTTPClient
    let checkImage: @Sendable (Data) -> ImageCheck
    let now: @Sendable () -> Double
    let onEvent: @Sendable (JSON) -> Void
    let sleepImpl: @Sendable (Double) async throws -> Void
    let randomDelayMs: @Sendable () -> Double

    nonisolated let globalSemaphore = AsyncSemaphore(10)
    private nonisolated let providerSemaphores = Locked<[String: AsyncSemaphore]>([:])
    private nonisolated let hedgesByBatch = Locked<[String: Int]>([:])
    private var inflightByScreen: [String: Task<GenerateResult, Error>] = [:]

    public init(
        getSettings: @escaping @Sendable () async throws -> Settings,
        updateProvider: @escaping @Sendable (String, SizeFallback) async -> Void = { _, _ in },
        secrets: SecretStore,
        ledger: Ledger,
        health: HealthStore,
        callLog: CallLog,
        http: HTTPClient,
        checkImage: @escaping @Sendable (Data) -> ImageCheck = { checkScreenImage($0) },
        now: @escaping @Sendable () -> Double = nowMs,
        onEvent: @escaping @Sendable (JSON) -> Void = { _ in },
        sleepImpl: @escaping @Sendable (Double) async throws -> Void = { try await sleepMs($0) },
        randomDelayMs: @escaping @Sendable () -> Double = { Double(2000 + Int.random(in: 0..<3000)) }
    ) {
        self.getSettings = getSettings
        self.updateProvider = updateProvider
        self.secrets = secrets
        self.ledger = ledger
        self.health = health
        self.callLog = callLog
        self.http = http
        self.checkImage = checkImage
        self.now = now
        self.onEvent = onEvent
        self.sleepImpl = sleepImpl
        self.randomDelayMs = randomDelayMs
    }

    nonisolated func providerSemaphore(_ provider: ImageProvider) -> AsyncSemaphore {
        let semaphore = providerSemaphores.withLock { table in
            if let existing = table[provider.id] { return existing }
            let created = AsyncSemaphore(provider.concurrency)
            table[provider.id] = created
            return created
        }
        semaphore.setLimit(provider.concurrency)
        return semaphore
    }

    nonisolated func takeHedgeSlot(_ batchId: String, limit: Int) -> Bool {
        hedgesByBatch.withLock { table in
            let used = table[batchId] ?? 0
            if used >= limit { return false }
            table[batchId] = used + 1
            return true
        }
    }

    nonisolated func secretList() async -> [String] { await secrets.values() }

    public nonisolated func hedgeThresholdMs(_ provider: ImageProvider, _ hedge: HedgeSettings) -> Double {
        let recent = callLog.recentSuccessSeconds(provider.id, window: 50)
        let base = recent.count >= 5 ? (percentile(recent, hedge.percentile == 0 ? 85 : hedge.percentile) ?? 60) : (provider.hedgeDefaultSec == 0 ? 60 : provider.hedgeDefaultSec)
        let clamped = min(hedge.maxSec == 0 ? 120 : hedge.maxSec, max(hedge.minSec == 0 ? 20 : hedge.minSec, base))
        return jsRound(clamped * 1000)
    }

    nonisolated func installFile(_ outputPath: String, _ png: Data, _ archiveRoot: String) throws {
        if FS.exists(outputPath) {
            // 同一分钟内替换的截图归档到同一个文件夹；同名时加序号，不覆盖已归档的旧图
            let archiveDir = Path.join(archiveRoot, "screens-\(timestampSlug(Date(timeIntervalSince1970: now() / 1000)).jsSlice(0, 16))")
            try FS.mkdirp(archiveDir)
            let base = Path.basename(outputPath, ".png")
            var target = Path.join(archiveDir, "\(base).png")
            var index = 2
            while FS.exists(target) {
                target = Path.join(archiveDir, "\(base)-\(index).png")
                index += 1
            }
            try FileManager.default.copyItem(atPath: outputPath, toPath: target)
        }
        try FS.writeAtomic(outputPath, png)
    }

    nonisolated func saveAlternate(alternatesDir: String, screenId: String, providerId: String, png: Data) throws -> String {
        let dir = Path.join(alternatesDir, screenId)
        try FS.mkdirp(dir)
        let file = Path.join(dir, "\(timestampSlug(Date(timeIntervalSince1970: now() / 1000)))-\(providerId).png")
        try FS.writeAtomic(file, png)
        return file
    }

    nonisolated func pickHedgeProvider(_ providers: [ImageProvider], _ current: ImageProvider, _ tried: [String], _ hedge: HedgeSettings) -> ImageProvider? {
        let candidates = providers.filter { $0.id != current.id && !tried.contains($0.id) && health.unavailableReason($0.id) == nil }
        let group = modelGroupOf(current)
        let host = hostOf(current.baseUrl)
        return candidates.first { modelGroupOf($0) == group && hostOf($0.baseUrl) != host }
            ?? candidates.first { modelGroupOf($0) == group }
            ?? (hedge.allowCrossModel ? candidates.first : nil)
    }

    /// 生成一屏。取消当前任务即取消这一屏的所有尝试。
    public func generate(_ request: GenerateRequest) async throws -> GenerateResult {
        if Task.isCancelled { throw ProviderError("已取消", kind: "aborted") }
        let key = "\(request.projectDir)::\(request.screenId)"
        if let inflight = inflightByScreen[key] {
            let result = try await inflight.value
            // 重启后续查的任务失败了：这一屏重新正常生成
            if result.resumed && !result.ok { return try await generate(request) }
            return result
        }
        let job = try await GatewayJob(gateway: self, request: request)
        let task = Task<GenerateResult, Error> { try await job.run() }
        inflightByScreen[key] = task
        defer { inflightByScreen[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await job.abortAll() }
        }
    }

    /// 软件重启后，把账本里还在等结果的异步任务接着查完。
    public func resumePending() async -> [String] {
        guard let settings = try? await getSettings() else { return [] }
        var resumed: [String] = []
        for (job, attempt) in ledger.remoteWaitingTyped() {
            guard let provider = settings.providers.first(where: { $0.id == attempt.providerId }) else { continue }
            let apiKey = await secrets.get(SecretIds.imageProvider(provider.id))
            if apiKey.isEmpty { continue }
            let jobId = job.jobId ?? ""
            let attemptId = attempt.attemptId ?? ""
            let taskId = attempt.taskId ?? ""
            let startedAt = now()
            let work = Task<Void, Never> { [ledger, callLog, http, checkImage, onEvent] in
                do {
                    let result = try await runAttempt(provider: provider, apiKey: apiKey, prompt: job.prompt ?? "", resumeTaskId: taskId, http: http)
                    let check = checkImage(result.bytes)
                    guard check.ok, let png = check.png else { throw ProviderError(check.reason ?? "图片无效", kind: "invalid-image") }
                    let latest = ledger.getTyped(jobId)
                    var outcome = "alternate"
                    var file: String
                    let state = latest?.state
                    if state == "running" || state == "interrupted" {
                        try self.installFile(job.outputPath ?? "", png, job.archiveRoot ?? "")
                        var jobDone = ImageJob(.emptyObject)
                        jobDone.state = "done"
                        jobDone.winnerAttemptId = attemptId
                        jobDone.providerId = provider.id
                        await ledger.finishJob(jobId, jobDone)
                        outcome = "winner"
                        file = job.outputPath ?? ""
                    } else {
                        file = try self.saveAlternate(alternatesDir: job.alternatesDir ?? "", screenId: job.screenId ?? "", providerId: provider.id, png: png)
                    }
                    var attemptDone = ImageAttempt(.emptyObject)
                    attemptDone.state = "completed"
                    attemptDone.outcome = outcome
                    attemptDone.resumed = true
                    await ledger.finishAttempt(jobId, attemptId, attemptDone)
                    await callLog.append(.obj([
                        "jobId": .string(jobId), "projectDir": job.projectDir.map(JSON.string), "screenId": job.screenId.map(JSON.string), "providerId": .string(provider.id),
                        "providerName": .string(provider.name), "model": .string(provider.model), "role": "resume", "ok": true, "kind": "success",
                        "outcome": .string(outcome), "durationMs": .number(self.now() - startedAt), "taskId": .string(taskId),
                    ]))
                    onEvent(.obj(["type": .string(outcome == "winner" ? "job-recovered" : "alternate"), "jobId": .string(jobId), "projectDir": job.projectDir.map(JSON.string), "screenId": job.screenId.map(JSON.string), "file": .string(file), "providerId": .string(provider.id)]))
                } catch {
                    var attemptFailed = ImageAttempt(.emptyObject)
                    attemptFailed.state = "failed"
                    attemptFailed.error = messageOf(error)
                    attemptFailed.resumed = true
                    await ledger.finishAttempt(jobId, attemptId, attemptFailed)
                    let state = ledger.getTyped(jobId)?.state
                    if state == "running" || state == "interrupted" {
                        var jobFailed = ImageJob(.emptyObject)
                        jobFailed.state = "failed"
                        jobFailed.error = messageOf(error)
                        await ledger.finishJob(jobId, jobFailed)
                    }
                }
            }
            let key = "\(job.projectDir ?? "")::\(job.screenId ?? "")"
            if inflightByScreen[key] == nil {
                let requestSize = attempt.requestSize
                let tracked = Task<GenerateResult, Error> { [ledger] in
                    await work.value
                    let latest = ledger.getTyped(jobId)
                    let ok = latest?.state == "done" && latest?.winnerAttemptId == attemptId
                    return GenerateResult(jobId: jobId, outputPath: job.outputPath ?? "", providerId: provider.id, providerName: provider.name, model: provider.model, requestSize: requestSize, width: nil, height: nil, durationMs: self.now() - startedAt, hedged: false, attempts: 1, warnings: [], resumed: true, ok: ok)
                }
                inflightByScreen[key] = tracked
                Task { _ = try? await tracked.value; self.clearInflight(key, tracked) }
            }
            resumed.append(jobId)
        }
        return resumed
    }

    private func clearInflight(_ key: String, _ task: Task<GenerateResult, Error>) {
        if inflightByScreen[key] == task { inflightByScreen[key] = nil }
    }

    /// 测试线路：先免费查模型列表，需要时再真实生成一张（会扣一张图的费用）。
    public func probe(_ providerId: String, realImage: Bool = false) async throws -> JSON {
        let settings = try await getSettings()
        guard var provider = settings.providers.first(where: { $0.id == providerId }) else { throw StudioError("线路不存在") }
        let apiKey = await secrets.get(SecretIds.imageProvider(provider.id))
        if apiKey.isEmpty { throw StudioError("这条线路还没有填写密钥") }
        let secretValues = await secretList()
        var report: JSON = ["providerId": .string(providerId), "models": nil, "hasModel": nil, "image": nil]
        do {
            let models = try await probeModels(provider: provider, apiKey: apiKey, http: http)
            report["models"] = JSON(Array(models.models.prefix(200)))
            report["hasModel"] = JSON.orNull(models.hasModel)
        } catch {
            let message = redact(messageOf(error), secretValues)
            report["modelsError"] = .string(message)
            if (error as? ProviderError)?.kind == "auth" { throw StudioError("鉴权失败：\(message)") }
        }
        if !realImage { return report }
        var sizeSpec = resolveRequestSize(provider, settings.image.targetSize)
        for round in 0..<2 {
            let startedAt = now()
            do {
                let timeout = provider.hardTimeoutSec == 0 ? 240 : provider.hardTimeoutSec
                let current = provider
                let size = sizeSpec.size
                let http = self.http
                let result = try await withDeadline(seconds: timeout) {
                    try await runAttempt(provider: current, apiKey: apiKey, prompt: PROBE_PROMPT, size: size, quality: "low", http: http)
                }
                let check = checkImage(result.bytes)
                let durationMs = now() - startedAt
                await callLog.append(.obj([
                    "providerId": .string(provider.id), "providerName": .string(provider.name), "model": .string(provider.model), "role": "probe",
                    "ok": .bool(check.ok), "kind": .string(check.ok ? "success" : "invalid-image"), "durationMs": .number(durationMs),
                    "requestSize": .string(sizeSpec.size), "width": JSON.maybe(check.width), "height": JSON.maybe(check.height),
                    "errorMessage": check.ok ? nil : JSON.string(check.reason ?? ""),
                ]))
                if check.ok { await health.reset(provider.id) }
                report["image"] = .obj([
                    "ok": .bool(check.ok), "durationMs": .number(durationMs), "requestSize": .string(sizeSpec.size),
                    "width": JSON.maybe(check.width), "height": JSON.maybe(check.height), "reason": JSON.maybe(check.reason),
                    "warnings": JSON(check.warnings),
                    "dataUrl": check.ok ? JSON.maybe(check.png.map { "data:image/png;base64,\($0.base64EncodedString())" }) : nil,
                ])
                return report
            } catch {
                let providerError = (error as? ProviderError) ?? (error is RequestTimedOut ? ProviderError("超过 \(JSON.formatNumber(provider.hardTimeoutSec)) 秒没有出图", kind: "timeout") : ProviderError(messageOf(error), kind: "unknown"))
                let message = redact(providerError.message, secretValues)
                await callLog.append(.obj([
                    "providerId": .string(provider.id), "providerName": .string(provider.name), "model": .string(provider.model), "role": "probe",
                    "ok": false, "kind": .string(providerError.kind), "durationMs": .number(now() - startedAt), "requestSize": .string(sizeSpec.size), "errorMessage": .string(message),
                ]))
                if providerError.kind == "size", round == 0, let fallback = sizeFallback(providerError, provider, settings.image.targetSize, sizeSpec.size) {
                    sizeSpec = fallback.spec
                    fallback.apply(to: &provider)
                    await updateProvider(provider.id, fallback)
                    report["sizeSwitched"] = .string(sizeSpec.size)
                    continue
                }
                report["image"] = .obj(["ok": false, "requestSize": .string(sizeSpec.size), "reason": .string(message), "kind": .string(providerError.kind)])
                return report
            }
        }
        return report
    }

    public nonisolated func providerStatus(_ provider: ImageProvider) -> JSON {
        let stats = (try? JSON.encode(callLog.stats(provider.id))) ?? .emptyObject
        return stats.merging(.obj(["unavailable": JSON.orNull(health.unavailableReason(provider.id)), "health": health.snapshot(provider.id)]))
    }
}
