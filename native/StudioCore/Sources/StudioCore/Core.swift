import Foundation

/// 组装所有核心服务。App 和测试都通过它使用核心功能。
public final class StudioCore: @unchecked Sendable {
    public let dataDir: String
    public let settingsStore: SettingsStore
    public let secrets: SecretStore
    public let callLog: CallLog
    public let llmLog: CallLog
    public let ledger: Ledger
    public let health: HealthStore
    public let projectStore: ProjectStore
    public let gateway: ImageGateway
    public let pipeline: Pipeline
    public let batch: BatchQueue
    public let http: HTTPClient
    public let appVersion: String
    let emitEvent: @Sendable (JSON) -> Void
    let indexFile: String
    let indexSerial = SerialQueue()
    let trashItem: @Sendable (String) throws -> Void

    /// - secrets：App 里用 LocalSecrets（secrets.json + 本机密钥文件）；测试用 MemorySecrets。
    public init(dataDir: String, secrets: SecretStore? = nil, http: HTTPClient = URLSessionHTTPClient(), visionImage: @escaping @Sendable (String) throws -> String = visionDataUrl, appVersion: String = "", onEvent: @escaping @Sendable (JSON) -> Void = { _ in }, gatewaySleep: (@Sendable (Double) async throws -> Void)? = nil, randomDelayMs: (@Sendable () -> Double)? = nil, llmRetryDelay: (@Sendable (Double) async throws -> Void)? = nil, trashItem: (@Sendable (String) throws -> Void)? = nil) async throws {
        try FS.mkdirp(dataDir)
        self.dataDir = dataDir
        self.trashItem = trashItem ?? { path in try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        self.http = http
        self.appVersion = appVersion
        let batchRef = Locked<BatchQueue?>(nil)
        let emit: @Sendable (JSON) -> Void = { event in
            onEvent(event)
            // 项目在批量之外跑完了（手动继续、确认规划、人工验收……），同步批量队列里那条记录
            if event["type"]?.string == "run-finished", event["status"]?.string == ProjectStatus.done.rawValue, let dir = event["projectDir"]?.string, let batch = batchRef.current {
                Task { await batch.settle { $0 == dir ? ProjectStatus.done.rawValue : nil } }
            }
        }
        emitEvent = emit
        let settingsStore = SettingsStore(dataDir: dataDir)
        self.settingsStore = settingsStore
        let secrets = secrets ?? LocalSecrets.open(dataDir: dataDir)
        self.secrets = secrets
        let callLog = CallLog(dataDir: dataDir, fileName: "image-calls.jsonl")
        self.callLog = callLog
        let llmLog = CallLog(dataDir: dataDir, fileName: "llm-calls.jsonl")
        self.llmLog = llmLog
        let ledger = Ledger(dataDir: dataDir)
        self.ledger = ledger
        await ledger.initialize()
        let health = HealthStore(dataDir: dataDir)
        self.health = health
        let projectStore = ProjectStore(dataDir: dataDir)
        self.projectStore = projectStore
        indexFile = Path.join(dataDir, "projects-index.json")
        let pipelineRef = Locked<Pipeline?>(nil)
        let gateway = ImageGateway(
            getSettings: { try await settingsStore.get() },
            updateProvider: { id, fallback in
                _ = try? await settingsStore.update { settings in
                    if let index = settings.providers.firstIndex(where: { $0.id == id }) { fallback.apply(to: &settings.providers[index]) }
                }
            },
            secrets: secrets, ledger: ledger, health: health, callLog: callLog, http: http,
            onEvent: { event in
                pipelineRef.current?.onImageEvent(event)
                var wrapped = event
                wrapped["kind"] = event["type"]
                wrapped["type"] = "image"
                emit(wrapped)
            },
            sleepImpl: gatewaySleep ?? { try await sleepMs($0) },
            randomDelayMs: randomDelayMs ?? { Double(2000 + Int.random(in: 0..<3000)) }
        )
        self.gateway = gateway
        let pipeline = Pipeline(settingsStore: settingsStore, secrets: secrets, gateway: gateway, projectStore: projectStore, llmLog: llmLog, emit: emit, http: http, visionImage: visionImage, appVersion: appVersion, statsFile: Path.join(dataDir, "step-durations.json"), llmRetryDelay: llmRetryDelay ?? { try await sleepMs($0) })
        self.pipeline = pipeline
        pipelineRef.withLock { $0 = pipeline }
        batch = BatchQueue(dataDir: dataDir, settingsStore: settingsStore, pipeline: pipeline, emit: emit)
        batchRef.withLock { $0 = batch }
        pipeline.isQueued = { dir in
            batchRef.current?.listTyped().items.contains {
                $0.projectDir == dir && ($0.status == .queued || $0.status == .running || $0.status == .paused)
            } ?? false
        }
        callLog.onAppend { row in emit(.obj(["type": "call", "row": row])) }
    }

    // MARK: - 项目索引：工作区里由本软件管理的项目

    func readIndex() -> JSON { FS.readJSONQuiet(indexFile) ?? ["projects": []] }

    func updateIndex(_ mutate: @escaping @Sendable (inout [JSON]) -> Void) async throws {
        let file = indexFile
        try await indexSerial.run {
            var index = FS.readJSONQuiet(file) ?? ["projects": []]
            var projects = index["projects"].items
            mutate(&projects)
            index["projects"] = .array(projects)
            try FS.writeJSONAtomic(file, index)
        }
    }

    func summarizeScreens(_ screens: JSON?) -> JSON {
        let values = screens.fields.values.filter { $0["status"]?.string != "kept" }
        if values.isEmpty { return .null }
        let finished = values.filter { ["generated", "passed"].contains($0["status"]?.string ?? "") }.count
        return .obj(["total": .number(Double(values.count)), "finished": .number(Double(finished)), "failed": .number(Double(values.filter { $0["status"]?.string == "failed" }.count))])
    }

    func queueIndex() -> [String: (item: BatchQueueItem, position: Int?)] {
        let items = batch.listTyped().items
        var map: [String: (item: BatchQueueItem, position: Int?)] = [:]
        var position = 0
        for item in items {
            let status = item.status
            if status == .queued { position += 1 }
            let dir = item.projectDir ?? ""
            // 同一项目在队列里有多条时，以「排队/运行中」的那条为准
            if map[dir] == nil || status == .queued || status == .running {
                map[dir] = (item, status == .queued ? position : nil)
            }
        }
        return map
    }

    func summarize(_ entry: JSON, _ settings: Settings, _ queueByDir: [String: (item: BatchQueueItem, position: Int?)]) -> JSON? {
        let dir = entry["dir"]?.jsString ?? ""
        guard let state = try? projectStore.readTyped(dir) else { return nil }
        let summaryStarted = ListPerformance.now
        defer { ListPerformance.addSummary(ListPerformance.now - summaryStarted) }
        let alive = FS.exists(dir)
        let queued = queueByDir[dir]
        let live = pipeline.getProgress(dir)
        let running = pipeline.isForegroundRunning(dir)
        var steps = JSONObject()
        for step in PIPELINE_STEPS {
            steps[step] = .string((state[step: PipelineStepName(rawValue: step)]?.status ?? .pending).rawValue)
        }
        let lastBuild = state.lastBuild
        let timing = state.timing
        let screenCount = state.screens.fields.count
        var summary = JSONObject()
        summary["dir"] = .string(dir)
        summary["thumbnail"] = ProjectThumbnail.read(dir: dir, state: state)?.raw ?? .null
        summary["name"] = state.request?.softwareName.map(JSON.string) ?? .null
        summary["origin"] = state.origin.map(JSON.string) ?? .null
        summary["grade"] = state.imported?["grade"].truthyValue ?? .null
        summary["readOnly"] = .bool(state.readOnly == true)
        summary["submitted"] = state.submitted?["at"].truthyValue ?? .null
        let status: ProjectStatus = !alive ? .missing : state.readOnly == true ? .readonly : running ? .running : (state.status.flatMap { $0.rawValue.isEmpty ? nil : $0 } ?? .idle)
        summary["status"] = .string(status.rawValue)
        summary["bundleUpdating"] = .bool(pipeline.bundleActive.current.contains(dir))
        summary["steps"] = .object(steps)
        summary["screens"] = .number(Double(screenCount > 0 ? screenCount : state.request?.screenCount ?? 0))
        summary["hasCodeSource"] = .bool(codeSourceFor(state, settings).source?["path"].isTruthy ?? false)
        summary["hasBundle"] = .bool((lastBuild?.raw.truthy ?? false) || state.origin == "imported")
        summary["bundleFiles"] = lastBuild?.files?.array.map { .number(Double($0.count)) } ?? .null
        summary["pdfFontProblem"] = .bool(lastBuild?.pdfFonts.fields.values.contains { $0.isObject && $0["ok"] == .bool(false) } ?? false)
        summary["timing"] = timing.isTruthy ? .obj(["totalMs": timing?["totalMs"] ?? .null, "completedMs": timing?["completedMs"].truthyValue ?? .null, "completedAt": timing?["completedAt"].truthyValue ?? .null, "lastMs": timing?["runs"]?.array?.last?["ms"].truthyValue ?? .null]) : .null
        summary["queue"] = queued.map {
            let err = $0.item.error.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? .null
            return .obj(["id": $0.item.id.map(JSON.string), "status": $0.item.status.map { .string($0.rawValue) }, "position": JSON.orNull($0.position), "error": err])
        } ?? .null
        summary["progress"] = live.map { .obj(["step": $0["step"], "started": $0["started"], "stepStarted": $0["stepStarted"], "screens": summarizeScreens($0["screens"]), "detail": $0["detail"]]) } ?? .null
        summary["feedbackPending"] = .number(Double((state.feedback ?? []).filter { $0.status == "pending" }.count))
        summary["lastBuildAt"] = lastBuild?.at.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? .null
        summary["lastError"] = state.lastError.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? .null
        summary["warnings"] = .number(Double(state.warnings.items.count))
        summary["addedAt"] = entry["addedAt"] ?? .null
        summary["updatedAt"] = state.log?.array?.last?["at"] ?? entry["addedAt"] ?? .null
        return .object(summary)
    }

    func emit(_ event: JSON) { emitEvent(event) }

    // MARK: - 设置

    public struct SettingsBundle: Sendable {
        public let settings: Settings
        public let providerKeys: [String: Bool]
        public let vendorKeys: [String: Bool]
    }

    public func getSettings() async throws -> SettingsBundle {
        let settings = try await settingsStore.get()
        var providerKeys: [String: Bool] = [:]
        for provider in settings.providers { providerKeys[provider.id] = await secrets.has(SecretIds.imageProvider(provider.id)) }
        var vendorKeys: [String: Bool] = [:]
        for vendor in settings.llm.vendors { vendorKeys[vendor.id] = await secrets.has(SecretIds.llmVendor(vendor.id)) }
        return SettingsBundle(settings: settings, providerKeys: providerKeys, vendorKeys: vendorKeys)
    }

    /// 只允许改这些顶层设置（线路、大模型有各自的接口）。
    @discardableResult
    public func updateSettings(_ patch: JSON) async throws -> Settings {
        let allowed = ["workspaceDir", "image", "pipeline", "txtFields", "codeDefaults", "codeSource", "pdf", "export"]
        var filtered = JSONObject()
        for (key, value) in patch.fields where allowed.contains(key) { filtered[key] = value }
        let next = try await settingsStore.update(patch: .object(filtered))
        // 调大「同时处理几个项目」后马上补上排队的项目
        if filtered["pipeline"] != nil { batch.kick() }
        return next
    }

    public func libreOfficeStatus() async -> String? {
        resetLibreOfficeCache()
        return await findLibreOffice()
    }

    // MARK: - 生图线路

    /// 保存线路；apiKey 为空表示不修改密钥。
    @discardableResult
    public func saveProvider(_ input: ImageProvider, apiKey: String? = nil) async throws -> String {
        let id = input.id.isEmpty ? "img-\(randomHex(3))" : input.id
        if input.baseUrl.jsTrimmed.isEmpty { throw StudioError("请填写接口地址") }
        if input.model.isEmpty { throw StudioError("请填写模型名") }
        var provider = input
        provider.id = id
        provider.baseUrl = Rx.replace("/+$", in: input.baseUrl.jsTrimmed, with: "")
        let saved = provider
        try await settingsStore.update { settings in
            if let index = settings.providers.firstIndex(where: { $0.id == id }) { settings.providers[index] = saved } else { settings.providers.append(saved) }
        }
        if let apiKey, !apiKey.jsTrimmed.isEmpty { try await secrets.set(SecretIds.imageProvider(id), apiKey.jsTrimmed) }
        await health.reset(id)
        return id
    }

    public func deleteProvider(_ id: String) async throws {
        try await settingsStore.update { $0.providers.removeAll { $0.id == id } }
        try await secrets.delete(SecretIds.imageProvider(id))
    }

    public func reorderProviders(_ ids: [String]) async throws {
        try await settingsStore.update { settings in
            var ordered = ids.compactMap { id in settings.providers.first { $0.id == id } }
            for provider in settings.providers where !ids.contains(provider.id) { ordered.append(provider) }
            settings.providers = ordered
        }
    }

    public func providerStatuses() async throws -> [String: JSON] {
        let settings = try await settingsStore.get()
        var result: [String: JSON] = [:]
        for provider in settings.providers {
            var status = gateway.providerStatus(provider)
            status["hedgeThresholdSec"] = .number(gateway.hedgeThresholdMs(provider, settings.image.hedge) / 1000)
            result[provider.id] = status
        }
        return result
    }

    public func probeProvider(_ id: String, realImage: Bool) async throws -> JSON { try await gateway.probe(id, realImage: realImage) }

    public func resetProviderHealth(_ id: String) async { await health.reset(id) }


    // MARK: - 大模型

    @discardableResult
    public func saveVendor(_ input: LlmVendor, apiKey: String? = nil) async throws -> String {
        let id = input.id.isEmpty ? "llm-\(randomHex(3))" : input.id
        if input.baseUrl.jsTrimmed.isEmpty { throw StudioError("请填写接口地址") }
        var vendor = input
        vendor.id = id
        vendor.baseUrl = Rx.replace("/+$", in: input.baseUrl.jsTrimmed, with: "")
        try await settingsStore.update { settings in
            if let index = settings.llm.vendors.firstIndex(where: { $0.id == id }) {
                var merged = vendor
                if merged.models.isEmpty { merged.models = settings.llm.vendors[index].models }
                settings.llm.vendors[index] = merged
            } else {
                settings.llm.vendors.append(vendor)
            }
        }
        if let apiKey, !apiKey.jsTrimmed.isEmpty { try await secrets.set(SecretIds.llmVendor(id), apiKey.jsTrimmed) }
        return id
    }

    public func deleteVendor(_ id: String) async throws {
        try await settingsStore.update { settings in
            for (step, value) in settings.llm.assignments where value?.vendorId == id { settings.llm.assignments[step] = .some(nil) }
            settings.llm.vendors.removeAll { $0.id == id }
        }
        try await secrets.delete(SecretIds.llmVendor(id))
    }

    public func fetchVendorModels(_ id: String) async throws -> [String] {
        let settings = try await settingsStore.get()
        guard let vendor = settings.llm.vendors.first(where: { $0.id == id }) else { throw StudioError("厂商不存在") }
        let apiKey = await secrets.get(SecretIds.llmVendor(id))
        if apiKey.isEmpty { throw StudioError("请先填写密钥") }
        let models = try await listModels(vendor: vendor, apiKey: apiKey, http: http)
        try await settingsStore.update { settings in
            if let index = settings.llm.vendors.firstIndex(where: { $0.id == id }) { settings.llm.vendors[index].models = models }
        }
        return models
    }

    /// 测试连接：先问一句话，再试一次「只输出 JSON」（规划、检查截图、写文字都要模型按 JSON 输出）。
    /// jsonProblem 为 nil 表示能按 JSON 输出。
    public func testVendor(_ id: String, model: String, vision: Bool) async throws -> (reply: String, ms: Double, jsonProblem: String?, diagnostics: String?) {
        let settings = try await settingsStore.get()
        guard let vendor = settings.llm.vendors.first(where: { $0.id == id }) else { throw StudioError("厂商不存在") }
        let apiKey = await secrets.get(SecretIds.llmVendor(id))
        let started = nowMs()
        let imageUrl = "data:image/png;base64,\(solidPng(64, 64, (220, 38, 38)).base64EncodedString())"
        let content: JSON = vision
            ? .array([["type": "text", "text": "这张图主要是什么颜色？只回答一个词。"], ["type": "image_url", "image_url": ["url": .string(vendor.preset == "zhipu" ? Rx.replaceFirst("^data:[^;]+;base64,", in: imageUrl, with: "") : imageUrl)]]])
            : "回复「连接正常」四个字。"
        // 输出额度给宽一点：推理模型会先用掉一部分去「思考」，太少的话正文还没开始写就到上限了
        let result = try await chatCompletion(vendor: vendor, apiKey: apiKey, model: model, messages: [["role": "user", "content": content]], maxTokens: 1024, jsonMode: false, http: http, timeoutSec: 60)
        let ms = nowMs() - started
        var jsonProblem: String?
        var diagnostics: [String] = []
        if let reason = result.emptyReason { diagnostics.append("【一句话测试】\(reason)\n\(result.diagnostics)") }
        do {
            let schema: JSON = ["type": "object", "required": ["ok", "steps"], "properties": ["ok": ["type": "boolean"], "steps": ["type": "array", "items": ["type": "string"]]]]
            _ = try await chatJson(vendor: vendor, apiKey: apiKey, model: model, request: ChatJsonRequest(system: "你是接口测试助手。", user: "输出 JSON：ok 为 true，steps 为三个中文短句组成的数组，描述打开一个记账 App 的三个步骤。", schema: schema, temperature: 0.2, maxTokens: 1024), http: http)
        } catch {
            jsonProblem = messageOf(error)
            if let detail = (error as? LlmError)?.detail { diagnostics.append("【按 JSON 输出测试】\n\(detail)") }
            // 再要一次原始返回，看清楚线路到底回了什么
            if let raw = try? await chatCompletion(vendor: vendor, apiKey: apiKey, model: model, messages: [["role": "system", "content": "只输出一个 JSON 对象。"], ["role": "user", "content": "输出 {\"ok\": true}"]], maxTokens: 1024, http: http, timeoutSec: 60) {
                diagnostics.append("【按 JSON 输出时线路的原始返回】\n\(raw.diagnostics)")
            }
        }
        return (result.text.jsSlice(0, 100), ms, jsonProblem, diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n\n"))
    }

    public func setAssignment(_ step: String, _ value: LlmAssignment?) async throws {
        guard LLM_STEPS[step] != nil else { throw StudioError("未知步骤") }
        try await settingsStore.update { $0.llm.assignments[step] = .some(value) }
    }
}
