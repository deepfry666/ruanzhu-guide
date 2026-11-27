import Foundation

/// 固定流水线：规划 → 提示词 → 生图 → 验收 → 文案 → 设计说明 → 回执 → 构建。
/// 每一步记录输入哈希，只重跑受影响的步骤。
public final class Pipeline: @unchecked Sendable {
    let settingsStore: SettingsStore
    let secrets: SecretStore
    let gateway: ImageGateway
    let projectStore: ProjectStore
    let llmLog: CallLog
    let emit: @Sendable (JSON) -> Void
    let http: HTTPClient
    let visionImage: @Sendable (String) throws -> String
    let appVersion: String
    let statsFile: String?
    let llmRetryDelay: @Sendable (Double) async throws -> Void

    final class RunHandle: @unchecked Sendable {
        var task: Task<RunResult, Never>?
        var bundleOnly = false
        let cancellable: Bool
        init(cancellable: Bool) { self.cancellable = cancellable }
        func cancel() { if cancellable { task?.cancel() } }
    }

    let running = Locked<[String: RunHandle]>([:])
    let progress = Locked<[String: JSON]>([:])
    let statsCache = Locked<JSON?>(nil)
    let bundleUpdates = BundleUpdates()
    var isQueued: @Sendable (String) -> Bool = { _ in false }
    let applying = Locked<Set<String>>([])

    public init(settingsStore: SettingsStore, secrets: SecretStore, gateway: ImageGateway, projectStore: ProjectStore, llmLog: CallLog, emit: @escaping @Sendable (JSON) -> Void = { _ in }, http: HTTPClient, visionImage: @escaping @Sendable (String) throws -> String = visionDataUrl, appVersion: String = "", statsFile: String? = nil, llmRetryDelay: @escaping @Sendable (Double) async throws -> Void = { try await sleepMs($0) }) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.gateway = gateway
        self.projectStore = projectStore
        self.llmLog = llmLog
        self.emit = emit
        self.http = http
        self.visionImage = visionImage
        self.appVersion = appVersion
        self.statsFile = statsFile
        self.llmRetryDelay = llmRetryDelay
    }

    // MARK: - 实时进度（只在内存里，运行结束就清掉）

    func setProgress(_ dir: String, _ patch: JSON) {
        let next: JSON? = progress.withLock { table in
            guard let current = table[dir] else { return nil }
            var next = current.merging(patch)
            next["updatedAt"] = .number(nowMs())
            table[dir] = next
            return next
        }
        if let next { emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": next])) }
    }

    func setScreenProgress(_ dir: String, _ id: String, _ patch: JSON) {
        let next: JSON? = progress.withLock { table in
            guard var current = table[dir] else { return nil }
            var screens = current["screens"] ?? .emptyObject
            screens[id] = (screens[id] ?? .emptyObject).merging(patch)
            current["screens"] = screens
            current["updatedAt"] = .number(nowMs())
            table[dir] = current
            return current
        }
        if let next { emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": next])) }
    }

    func progressScreens(_ dir: String) -> JSON { progress.withLock { $0[dir]?["screens"] } ?? .emptyObject }
    func doneSteps(_ dir: String) -> [JSON] { progress.withLock { $0[dir]?["doneSteps"]?.array } ?? [] }

    /// 生图网关的事件（哪条线路、有没有补发）同步到进度里。
    public func onImageEvent(_ event: JSON) {
        guard let dir = event["projectDir"]?.string, let id = event["screenId"]?.string, progress.withLock({ $0[dir] != nil }) else { return }
        let type = event["type"]?.string
        if type == "attempt-start" {
            let attempts = (progressScreens(dir)[id]?["attempts"]?.number ?? 0) + 1
            var patch: JSON = ["provider": event["providerName"] ?? .null, "attempts": .number(attempts)]
            if event["role"]?.string == "hedge" { patch["hedged"] = true }
            setScreenProgress(dir, id, patch)
        } else if type == "hedge" {
            setScreenProgress(dir, id, ["hedged": true])
        }
    }

    public func getProgress(_ dir: String) -> JSON? { progress.withLock { $0[dir] } }
    public func isRunning(_ dir: String) -> Bool { running.withLock { $0[dir] != nil } }
    public func isForegroundRunning(_ dir: String) -> Bool { running.withLock { $0[dir] != nil && $0[dir]?.bundleOnly != true } }
    let bundleActive = Locked<Set<String>>([])
    public func runningProjects() -> [String] { running.withLock { Array($0.keys) } }

    // MARK: - 各步骤历史用时（估算剩余时间用）

    func loadStats() -> JSON {
        statsCache.withLock { cache in
            if let cache { return cache }
            let loaded = statsFile.flatMap { FS.readJSONQuiet($0) }.flatMap { $0.isObject ? $0 : nil } ?? .emptyObject
            cache = loaded
            return loaded
        }
    }

    func addStepSamples(_ samples: [String: Double]) {
        _ = loadStats()
        let snapshot: JSON = statsCache.withLock { cache in
            var stats = cache ?? .emptyObject
            for step in PIPELINE_STEPS {
                guard let ms = samples[step], ms > 300 else { continue }
                let list = (stats[step]?.array ?? []) + [.number(jsRound(ms))]
                stats[step] = .array(Array(list.suffix(30)))
            }
            cache = stats
            return stats
        }
        if let statsFile { try? FS.writeJSONAtomic(statsFile, snapshot) }
    }

    public func stepEstimates() -> [String: Double] {
        var result: [String: Double] = [:]
        for (step, samples) in loadStats().fields {
            let values = samples.items.compactMap(\.number)
            if values.count < 2 { continue }
            result[step] = values.sorted()[values.count / 2]
        }
        return result
    }

    // MARK: - 大模型

    public func resolveLlm(_ step: String) async -> (vendor: LlmVendor, model: String, apiKey: String)? {
        guard let settings = try? await settingsStore.get(), let assignment = settings.llm.assignment(step), !assignment.vendorId.isEmpty, !assignment.model.isEmpty,
              let vendor = settings.llm.vendors.first(where: { $0.id == assignment.vendorId }) else { return nil }
        let apiKey = await secrets.get(SecretIds.llmVendor(vendor.id))
        if apiKey.isEmpty { return nil }
        return (vendor, assignment.model, apiKey)
    }

    func callLlm(_ step: String, _ dir: String, _ request: ChatJsonRequest) async throws -> JSON {
        guard let llm = await resolveLlm(step) else {
            throw StudioError("还没有给「\(LLM_STEPS[step]?.label ?? step)」配置大模型（大模型页面里选择厂商和模型，并填写密钥）")
        }
        let started = nowMs()
        let retries = Locked(0)
        var request = request
        let label = LLM_STEPS[step]?.label ?? step
        request.onRetry = { [weak self] attempt, problem in
            retries.withLock { $0 = attempt }
            try? await self?.log(dir, "「\(label)」第 \(attempt) 次输出不合格，让模型重写（已用 \(Int((nowMs() - started) / 1000)) 秒）：\(problem.jsSlice(0, 300))", "warn")
        }
        do {
            let result = try await chatJson(vendor: llm.vendor, apiKey: llm.apiKey, model: llm.model, request: request, http: http, retryDelay: llmRetryDelay)
            await llmLog.append(.obj(["step": .string(step), "projectDir": .string(dir), "vendorId": .string(llm.vendor.id), "model": .string(llm.model), "ok": true, "durationMs": .number(nowMs() - started), "attempts": .number(Double(retries.withLock { $0 } + 1))]))
            let at = isoNow()
            let vendor = llm.vendor
            let model = llm.model
            try await updateRecord(dir) { record in
                record["llm"]?[step] = .obj(["vendor": .string(vendor.name), "baseUrl": .string(vendor.baseUrl), "model": .string(model), "at": .string(at)])
                record.append("history", .obj(["at": .string(at), "event": "llm", "step": .string(step), "vendor": .string(vendor.name), "model": .string(model)]))
            }
            return result
        } catch {
            let detail = (error as? LlmError)?.detail
            await llmLog.append(.obj(["step": .string(step), "projectDir": .string(dir), "vendorId": .string(llm.vendor.id), "model": .string(llm.model), "ok": false, "durationMs": .number(nowMs() - started), "errorMessage": .string(messageOf(error).jsSlice(0, 400)), "errorKind": JSON.orNull((error as? LlmError)?.kind), "errorDetail": JSON.orNull(detail?.jsSlice(0, 6000))]))
            if let detail { try? await log(dir, "「\(LLM_STEPS[step]?.label ?? step)」失败现场（模型回的内容摘录）：\n\(detail.jsSlice(0, 1500))", "warn") }
            throw error
        }
    }

    // MARK: - 状态

    @discardableResult
    func updateState(_ dir: String, _ mutate: @escaping @Sendable (inout ProjectState) throws -> Void) async throws -> ProjectState {
        let state = try await projectStore.updateTyped(dir, mutate)
        emit(.obj(["type": "project", "projectDir": .string(dir), "status": state.status.map { .string($0.rawValue) } ?? .null, "steps": state.steps ?? .null]))
        return state
    }

    @discardableResult
    func update(_ dir: String, _ mutate: @escaping @Sendable (inout JSON) throws -> Void) async throws -> JSON {
        try await updateState(dir) { try mutate(&$0.raw) }.raw
    }

    func log(_ dir: String, _ message: String, _ level: String = "info") async throws {
        try await updateState(dir) { appendLog(&$0, message, level) }
        emit(.obj(["type": "log", "projectDir": .string(dir), "message": .string(message), "level": .string(level)]))
    }

    func readTypedState(_ dir: String) throws -> ProjectState {
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目状态不存在：\(dir)") }
        return state
    }

    func readState(_ dir: String) throws -> JSON {
        try readTypedState(dir).raw
    }

    func platformOf(_ state: ProjectState, _ settings: Settings) -> String {
        let platform = state.request?.platform ?? ""
        return platform.isEmpty ? settings.pipeline.platform : platform
    }

    func softwareName(_ state: ProjectState) -> String { state.request?.softwareName ?? "" }
    func softwareName(_ state: JSON) -> String { softwareName(ProjectState(state)) }

    /// 截图验收结果在这些条件不变时才有效：禁词，以及设置了内容日期的项目的日期规则。
    func gateKey(_ state: ProjectState) -> String {
        let tokens = JSON(forbiddenBrandTokens(softwareName(state), extraTokens(state)))
        guard let dates = datePolicyFields(state) else { return hashObject(tokens) }
        return hashObject(.obj(["tokens": tokens, "dates": dates]))
    }

    func extraTokens(_ state: ProjectState) -> [String] { state.request?.extraBrandTokens.items.map(\.jsString) ?? [] }
}
