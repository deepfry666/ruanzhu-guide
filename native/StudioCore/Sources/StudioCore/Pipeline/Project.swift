import Foundation
import CryptoKit

public let STATE_VERSION = 1

public func screenId(_ index: Int) -> String { "screen-\(String(index + 1).padStart(2))" }

public struct ProjectPaths: Sendable {
    public let dir: String
    public var prompts: String { Path.join(dir, "prompts") }
    public var screens: String { Path.join(dir, "screens") }
    public var alternates: String { Path.join(dir, "screens", "alternates") }
    public var archive: String { Path.join(dir, "archive") }
    public var content: String { Path.join(dir, "content.json") }
    public var profile: String { Path.join(dir, "software-profile.json") }
    public var featureMap: String { Path.join(dir, "feature-map.json") }
    public var screenPlan: String { Path.join(dir, "screen-plan.json") }
    public var uiContract: String { Path.join(dir, "ui-contract.json") }
    public var manifest: String { Path.join(dir, "project-manifest.json") }
    public var regionIndex: String { Path.join(dir, "region-index.json") }
    public func screenFile(_ id: String) -> String { Path.join(dir, "screens", "\(id).png") }
    public func promptFile(_ id: String) -> String { Path.join(dir, "prompts", "\(id).md") }
    public func bundle(_ softwareName: String) -> String { Path.join(dir, softwareName) }
}

public func projectPaths(_ dir: String) -> ProjectPaths { ProjectPaths(dir: dir) }

/// 创建新项目的初始状态（字段格式固定，供项目持久化与导入共用）。
public func newState(_ request: JSON) -> JSON {
    let req = ProjectRequest(request)
    var fields = ProjectRequest(.emptyObject)
    fields.softwareName = req.softwareName ?? request["softwareName"].text
    fields.versionPolicy = (req.versionPolicy?.isEmpty == false ? req.versionPolicy : nil) ?? "in-name"
    fields.applicableVersion = req.applicableVersion ?? ""
    if let count = req.screenCount, count != 0 { fields.screenCount = count } else { fields.raw["screenCount"] = .null }
    fields.emphasis = req.emphasis ?? ""
    fields.notes = req.notes ?? ""
    fields.platform = req.platform ?? ""
    fields.wantDesign = request["wantDesign"].isTruthy
    fields.codeSource = req.codeSource.or(.null)
    // 新建时就分好的代码模板记在项目上，之后改设置不影响它
    if req.codeSourceLocked == true { fields.codeSourceLocked = true }
    // 1.6.0 起新建的项目：生图提示词带内容红线
    if let version = req.policyVersion { fields.policyVersion = version }
    fields.txtFields = req.txtFields.or(.null)
    fields.extraBrandTokens = req.extraBrandTokens.or([])
    if let date = req.contentDate { fields.contentDate = date }
    if let date = req.earliestDate { fields.earliestDate = date }
    fields.compileDate = req.compileDate ?? ""
    fields.createdAt = (req.createdAt?.isEmpty == false ? req.createdAt : nil) ?? isoNow().jsSlice(0, 10)
    var state = ProjectState(.emptyObject)
    state.schemaVersion = STATE_VERSION
    state.request = fields
    state.status = .idle
    state.steps = .emptyObject
    for step in PIPELINE_STEPS {
        var stepState = StepState(.emptyObject)
        stepState.status = .pending
        state[step: PipelineStepName(rawValue: step)] = stepState
    }
    state.screens = .emptyObject
    state.warnings = []
    state.log = []
    state.origin = (request["origin"]?.truthy == true ? request["origin"]?.string : nil) ?? "created"
    return state.raw
}

// MARK: - 流水线内部辅助字段与保序 null 写入（不改动 Model/ 外壳定义，通过 raw 保序透传）

extension ProjectState {
    var bundleRevision: Double? {
        get { raw["bundleRevision"]?.number }
        set { raw["bundleRevision"] = newValue.map(JSON.number) }
    }
    var bundleUpdateError: String? {
        get { raw["bundleUpdateError"]?.string }
        set { raw["bundleUpdateError"] = newValue.map(JSON.string) }
    }
    var bundleUpdateNotice: String? {
        get { raw["bundleUpdateNotice"]?.string }
        set { raw["bundleUpdateNotice"] = newValue.map(JSON.string) }
    }
    var promptsName: String? {
        get { raw["promptsName"]?.string }
        set { raw["promptsName"] = newValue.map(JSON.string) }
    }
    var overviewEdited: Bool? {
        get { raw["overviewEdited"]?.bool }
        set { raw["overviewEdited"] = newValue.map(JSON.bool) }
    }
    var designEdited: Bool? {
        get { raw["designEdited"]?.bool }
        set { raw["designEdited"] = newValue.map(JSON.bool) }
    }
    var contentPlanHash: String? {
        get { raw["contentPlanHash"]?.string }
        set { raw["contentPlanHash"] = newValue.map(JSON.string) }
    }
    var pdfReexportedAt: String? {
        get { raw["pdfReexportedAt"]?.string }
        set { raw["pdfReexportedAt"] = newValue.map(JSON.string) }
    }
    var codeTemplateUpdatedAt: String? {
        get { raw["codeTemplateUpdatedAt"]?.string }
        set { raw["codeTemplateUpdatedAt"] = newValue.map(JSON.string) }
    }
    var imported: JSON? {
        get { raw["imported"] }
        set { raw["imported"] = newValue }
    }
    mutating func clearLastError() { raw["lastError"] = .null }
}

extension ProjectRequest {
    var allowDropCodeDoc: Bool? {
        get { raw["allowDropCodeDoc"]?.bool }
        set { raw["allowDropCodeDoc"] = newValue.map(JSON.bool) }
    }
}

extension ScreenState {
    var planRowHash: String? {
        get { raw["planRowHash"]?.string }
        set { raw["planRowHash"] = newValue.map(JSON.string) }
    }
    mutating func setPromptHashOrNull(_ value: String?) { raw["promptHash"] = JSON.orNull(value) }
    mutating func setImagePromptHashOrNull(_ value: String?) { raw["imagePromptHash"] = JSON.orNull(value) }
}

extension StepState {
    mutating func clearError() { raw["error"] = .null }
    mutating func clearInputHash() { raw["inputHash"] = .null }
    mutating func clearMessage() { raw["message"] = .null }
    static func completed(status: StepStatus, inputHash: String?, finishedAt: String, message: String?) -> StepState {
        StepState(.obj(["status": .string(status.rawValue), "inputHash": JSON.orNull(inputHash), "finishedAt": .string(finishedAt), "message": JSON.orNull(message)]))
    }
}

/// 项目状态文件名：规范路径的 SHA-1 前 16 位（固定映射，便于导入历史项目时对应状态文件）。
public func projectKey(_ dir: String) -> String {
    String(Insecure.SHA1.hash(data: Data(Path.resolve(dir).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
}

/// 项目状态存在软件自己的数据目录里（不往项目文件夹写隐藏文件），
/// 每个项目的写操作排队执行，避免多个步骤同时改状态。
public final class ProjectStore: @unchecked Sendable {
    public let dataDir: String
    public let stagingRoot: String
    private let stateCache = ProjectStateCache()
    private let queues = Locked<[String: SerialQueue]>([:])

    public init(dataDir: String) {
        self.dataDir = dataDir
        stagingRoot = Path.join(dataDir, "staging")
    }

    private func queue(_ dir: String) -> SerialQueue {
        queues.withLock { table in
            if let existing = table[dir] { return existing }
            let created = SerialQueue()
            table[dir] = created
            return created
        }
    }

    public func stateFile(_ dir: String) -> String { Path.join(dataDir, "projects", "\(projectKey(dir)).json") }

    public func readTyped(_ dir: String) throws -> ProjectState? {
        guard var state = try stateCache.read(stateFile(dir)) else { return nil }
        for step in PIPELINE_STEPS {
            let name = PipelineStepName(rawValue: step)
            if state[step: name] == nil {
                var pending = StepState(.emptyObject)
                pending.status = .pending
                state[step: name] = pending
            }
        }
        state.dir = dir
        return state
    }

    public func read(_ dir: String) throws -> JSON? {
        try readTyped(dir)?.raw
    }

    public func exists(_ dir: String) -> Bool { FS.exists(stateFile(dir)) }

    public func writeTyped(_ dir: String, _ state: ProjectState) async throws {
        let file = stateFile(dir)
        var next = state
        next.dir = dir
        let snapshot = next
        try await queue(dir).run { [self] in try stateCache.write(file, snapshot) }
    }

    public func write(_ dir: String, _ state: JSON) async throws {
        try await writeTyped(dir, ProjectState(state))
    }

    /// 读出当前状态 → 修改 → 写回（同一个项目排队执行）。
    @discardableResult
    public func updateTyped(_ dir: String, _ mutate: @escaping @Sendable (inout ProjectState) throws -> Void) async throws -> ProjectState {
        let file = stateFile(dir)
        return try await queue(dir).run { [self] in
            guard var state = try self.readTyped(dir) else { throw StudioError("项目状态不存在：\(dir)") }
            try mutate(&state)
            state.dir = dir
            try stateCache.write(file, state)
            return state
        }
    }

    @discardableResult
    public func update(_ dir: String, _ mutate: @escaping @Sendable (inout JSON) throws -> Void) async throws -> JSON {
        try await updateTyped(dir) { state in
            try mutate(&state.raw)
        }.raw
    }

    public func remove(_ dir: String) async {
        let file = stateFile(dir)
        _ = try? await queue(dir).run { [self] in stateCache.remove(file) }
    }

    /// 项目文件夹改名后，把状态搬到新路径名下。
    public func move(_ fromDir: String, _ toDir: String) throws {
        guard var state = try readTyped(fromDir) else { return }
        state.dir = toDir
        try stateCache.write(stateFile(toDir), state)
        stateCache.remove(stateFile(fromDir))
    }
}

/// 读规划。历史项目的规划格式不统一：数组 / { screens } / { flow }，行里用 id 或 screenId。
public func readPlan(_ dir: String) throws -> JSON? {
    let paths = projectPaths(dir)
    let profile = try FS.readJSON(paths.profile)
    let featureMap = try FS.readJSON(paths.featureMap)
    let uiContract = try FS.readJSON(paths.uiContract)
    guard let screenPlan = try FS.readJSON(paths.screenPlan), screenPlan.truthy else { return nil }
    let listed: JSON = screenPlan.isArray ? screenPlan : screenPlan["screens"].or(screenPlan["flow"] ?? .null)
    var rows: [JSON] = listed.items
    rows = rows.map { row in
        if let title = row.string { return ["title": .string(title)] }
        return row.isObject ? row : .emptyObject
    }
    if rows.isEmpty {
        // 规划里一屏都读不到时，按文案里的界面补齐，避免把已有文案当成「0 屏」
        let content = FS.readJSONQuiet(paths.content)
        rows = (content?["screens"]?.array ?? []).map { .obj(["title": $0["title"]]) }
    }
    var screens: [JSON] = []
    for (index, screen) in rows.enumerated() {
        var next = screen
        let fallback = JSON.string(screenId(index))
        next["id"] = screen["id"].or(screen["screenId"].or(fallback))
        next["title"] = screen["title"].or(screen["name"].or(screen["purpose"].or(fallback)))
        screens.append(next)
    }
    if screens.isEmpty { return nil }
    var planObject = screenPlan.isArray ? JSON.emptyObject : screenPlan
    planObject["screens"] = .array(screens)
    var result = JSONObject()
    result["profile"] = profile ?? .null
    result["featureMap"] = featureMap ?? .null
    result["screenPlan"] = planObject
    result["uiContract"] = uiContract ?? .null
    result["screens"] = .array(screens)
    return .object(result)
}

public func listScreenFiles(_ dir: String) -> [String] {
    (FS.list(projectPaths(dir).screens) ?? []).filter { Rx.test("^screen-[0-9]+\\.png$", $0, "i") }.sorted()
}

public func listAlternates(_ dir: String, _ id: String) -> [JSON] {
    let folder = Path.join(projectPaths(dir).alternates, id)
    let names = (FS.list(folder) ?? []).filter { $0.hasSuffix(".png") }.sorted().reversed()
    return names.map { .obj(["file": .string(Path.join(folder, $0)), "name": .string($0)]) }
}

public func appendLog(_ state: inout ProjectState, _ message: String, _ level: String = "info") {
    var log = state.log?.array ?? []
    log.append(.obj(["at": .string(isoNow()), "level": .string(level), "message": .string(message)]))
    if log.count > 400 { log.removeFirst(log.count - 400) }
    state.log = .array(log)
}

public func appendLog(_ state: inout JSON, _ message: String, _ level: String = "info") {
    var typed = ProjectState(state)
    appendLog(&typed, message, level)
    state = typed.raw
}
