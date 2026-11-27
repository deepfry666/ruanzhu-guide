import Foundation
import StudioCore

/// 界面用的步骤名（比核心里的更短）。
nonisolated let STEP_ORDER: [PipelineStepName] = PIPELINE_STEPS.map(PipelineStepName.init(rawValue:))
let UI_STEP_LABELS: [PipelineStepName: String] = [
    .plan: "规划界面", .prompts: "提示词", .images: "生成截图", .gate: "检查截图",
    .content: "撰写文案", .design: "设计说明", .receipt: "核对记录", .build: "交付包",
]

enum Tone {
    case neutral, blue, green, orange, red, purple, cyan, gold

    init(_ name: String) {
        switch name {
        case "processing", "blue": self = .blue
        case "success", "green": self = .green
        case "warning", "orange": self = .orange
        case "error", "red": self = .red
        case "purple": self = .purple
        case "cyan": self = .cyan
        case "gold": self = .gold
        default: self = .neutral
        }
    }
}

let PROJECT_STATUS: [ProjectStatus: (label: String, tone: Tone)] = [
    .idle: ("未完成", .neutral),
    .running: ("运行中", .blue),
    .done: ("已完成", .green),
    .waiting: ("等待确认", .orange),
    .needsAttention: ("需要处理", .red),
    .canceled: ("已停止", .neutral),
    .missing: ("文件夹不见了", .red),
    .readonly: ("只读", .neutral),
    .submitted: ("已提交", .purple),
]

let GRADE_LABEL: [String: (label: String, tone: Tone)] = [
    "ready": ("可直接编辑", .green),
    "needs-gate": ("待重新检查", .orange),
    "readonly": ("只读", .neutral),
]

let PLATFORMS: [(value: String, label: String)] = [
    ("iPhone 16 Pro Max / iOS 26", "iPhone 16 Pro Max / iOS 26"),
    ("Android 手机（原生 Android 界面）", "Android 手机"),
]

/// TXT 开头的 8 个字段，名字和 TXT 里一样
let TXT_LABELS: [(key: String, label: String)] = [
    ("devHardware", "开发的硬件环境"),
    ("runHardware", "运行的硬件环境"),
    ("devOs", "开发该软件的操作系统"),
    ("devTools", "软件开发环境 / 开发工具"),
    ("runPlatform", "运行平台 / 操作系统"),
    ("runSupport", "运行支撑环境 / 支持软件"),
    ("language", "编程语言"),
    ("sourceLines", "源程序量"),
]

/// 列表唯一归属；搜索、时间与批次筛选不改变项目本身的分组。
nonisolated enum ProjectGroup: String, CaseIterable {
    case attention, inProgress, completed, submitted

    var title: String {
        switch self {
        case .attention: "需要处理"
        case .inProgress: "进行中"
        case .completed: "已完成"
        case .submitted: "已提交"
        }
    }
}

/// 优先级：已提交 → 实际运行/队列 → 异常 → 只读/完成。
/// bundleUpdating 不改变归属，完成的项目更新交付包时仍归已完成。
nonisolated func projectGroup(_ row: ProjectRow) -> ProjectGroup {
    if row.submitted || row.status == .submitted { return .submitted }
    if row.status == .running || row.queueItem?.status.map({ [.queued, .paused, .running].contains($0) }) == true { return .inProgress }
    if row.status == .missing || row.pdfFontProblem { return .attention }
    if row.historyReadOnly || row.status == .readonly || row.status == .done { return .completed }
    return .attention
}

/// 历史项目列表的一行（封装 `listProjects()` 返回的汇总对象，状态与步骤暴露为类型化外壳）。
nonisolated struct ProjectRow: Identifiable, Hashable, Sendable {
    let json: JSON
    /// 新建、生成、完成、最近改动的时间（列表按日期筛选用，载入时解析一次）。导入的项目不算导入那天。
    let activityDates: [Date]

    init(json: JSON) {
        self.json = json
        let imported = json["origin"]?.string == "imported"
        let added = parseISO(json["addedAt"]?.string)
        var stamps = [parseISO(json["lastBuildAt"]?.string), parseISO(json["timing"]?["completedAt"]?.string)]
        if !imported { stamps.append(added) }
        if let updated = parseISO(json["updatedAt"]?.string), !imported || updated - (added ?? 0) > 10 * 60_000 { stamps.append(updated) }
        activityDates = stamps.compactMap { $0 }.map { Date(timeIntervalSince1970: $0 / 1000) }
        recency = activityDates.map(\.timeIntervalSince1970).max() ?? 0
    }
    var id: String { dir }
    var dir: String { json["dir"]?.string ?? "" }
    var name: String { json["name"]?.jsString ?? Path.basename(dir) }
    var origin: String { json["origin"]?.string ?? "created" }
    var grade: String? { json["grade"]?.string }
    /// 只有交付包的历史项目
    var historyReadOnly: Bool { json["readOnly"].isTruthy }
    /// 已提交：只读，批量操作跳过
    var submitted: Bool { json["submitted"].isTruthy }
    var readOnly: Bool { historyReadOnly || submitted }
    var status: ProjectStatus { json["status"]?.string.map(ProjectStatus.init(rawValue:)) ?? .idle }
    func step(_ name: PipelineStepName) -> StepStatus { json["steps"]?[name.rawValue]?.string.map(StepStatus.init(rawValue:)) ?? .pending }
    var thumbnail: ProjectThumbnail? { ProjectThumbnail(raw: json["thumbnail"]) }
    var hasBundle: Bool { json["hasBundle"].isTruthy }
    var bundleFiles: Int? { json["bundleFiles"]?.int }
    var bundleUpdating: Bool { json["bundleUpdating"].isTruthy }
    var pdfFontProblem: Bool { json["pdfFontProblem"].isTruthy }
    var timing: JSON? { json["timing"].truthyValue }
    var queueItem: BatchQueueItem? { json["queue"].truthyValue.map(BatchQueueItem.init) }
    /// 队列中的排队位次（列表汇总接口附带的衍生字段，不在持久化 `BatchQueueItem` 中）。
    var queuePosition: Int? { json["queue"]?["position"]?.int }
    var progress: JSON? { json["progress"].truthyValue }
    var liveStep: PipelineStepName? { progress?["step"]?.string.map(PipelineStepName.init(rawValue:)) }
    var feedbackPending: Int { json["feedbackPending"]?.int ?? 0 }
    var lastBuildAt: String? { json["lastBuildAt"]?.string }
    var lastError: String? { json["lastError"]?.string }
    var updatedAt: String { json["updatedAt"]?.string ?? "" }
    var addedAt: String { json["addedAt"]?.string ?? "" }
    /// 同一次批量新建的项目（没有批次时为 nil）
    var batchId: String? { json["batch"]?["id"]?.string }
    var batchLabel: String { json["batch"]?["label"]?.string ?? "" }
    var batchCount: Int { json["batch"]?["count"]?.int ?? 0 }

    /// 最近动过的时间（新建、修改、运行、生成交付包里最晚的一次，秒），列表默认按它排；载入时算一次
    let recency: Double
    var statusSortKey: String { submitted ? "已提交" : status.rawValue }
    var lastBuildSortKey: String { lastBuildAt ?? "" }

    /// 用时列：完成用时，没完成时显示累计
    var mainDurationMs: Double? { timing.flatMap { $0["completedMs"]?.number ?? $0["totalMs"]?.number } }

    var stepSummary: (done: Int, current: PipelineStepName?) {
        let done = STEP_ORDER.filter { [.done, .skipped].contains(step($0)) }.count
        return (done, STEP_ORDER.first { ![.done, .skipped].contains(step($0)) })
    }

    var livePercent: Double {
        guard let live = progress, let current = liveStep, let index = STEP_ORDER.firstIndex(of: current) else { return 0.02 }
        var inside = 0.3
        if [PipelineStepName.images, .gate].contains(current), let screens = live["screens"].truthyValue {
            inside = (screens["finished"]?.number ?? 0) / max(1, screens["total"]?.number ?? 1)
        }
        return max(0.02, min(0.99, (Double(index) + inside) / Double(STEP_ORDER.count)))
    }

    static func == (lhs: ProjectRow, rhs: ProjectRow) -> Bool { lhs.json == rhs.json }
    func hash(into hasher: inout Hasher) { hasher.combine(dir) }
}

/// 项目详情（getProject 的结果），内部建立在核心库 `ProjectState` 外壳之上。
struct ProjectData {
    let json: JSON
    var dir: String { json["dir"]?.string ?? "" }
    var projectState: ProjectState { ProjectState(json["state"] ?? .emptyObject) }
    /// 供核心库仍接收原始 `JSON` 的辅助函数使用（#18 之前保持兼容）。
    var state: JSON { projectState.raw }
    var request: ProjectRequest { projectState.request ?? ProjectRequest(.emptyObject) }
    var name: String { request.softwareName ?? "" }
    var status: ProjectStatus { projectState.status ?? .idle }
    var runningFlag: Bool { json["running"].isTruthy }
    /// 只有交付包的历史项目
    var historyReadOnly: Bool { projectState.readOnly ?? false }
    /// 已提交：只读，要改先取消
    var submitted: Bool { isSubmitted(projectState.raw) }
    var submittedAt: String? { projectState.submitted?["at"]?.string }
    var readOnly: Bool { historyReadOnly || submitted }
    var origin: String { projectState.origin ?? "created" }
    var lastError: String? { projectState.lastError }
    /// 交付包自动更新运行态标记（#04 新增字段，尚未收录到 `ProjectState` 固定属性）。
    var bundleUpdating: Bool { projectState.raw["bundleUpdating"].isTruthy }
    var bundleUpdateError: String? { projectState.raw["bundleUpdateError"]?.string }
    var bundleUpdateNotice: String? { projectState.raw["bundleUpdateNotice"]?.string }
    var plan: JSON? { json["plan"].truthyValue }
    var content: JSON? { json["content"].truthyValue }
    var screens: [ScreenItem] { json["screens"].items.map(ScreenItem.init) }
    var bundleDir: String { json["bundleDir"]?.string ?? "" }
    var bundleFiles: [String] { json["bundleFiles"].items.compactMap(\.string) }
    var codeSource: JSON { json["codeSource"] ?? .emptyObject }
    var warnings: [String] { projectState.warnings?.items.map(\.jsString) ?? [] }
    var log: [JSON] { projectState.log?.items ?? [] }
    var feedbackItems: [FeedbackItem] { projectState.feedback ?? [] }
    var pendingFeedbackItems: [FeedbackItem] { feedbackItems.filter { $0.status == "pending" } }
    /// 文字的历史版本（新的在前）
    var contentHistory: [JSON] { json["contentHistory"].items }
    /// 上次生成后在软件外被改过的交付文件
    var externalEdits: [String] { json["externalEdits"].items.compactMap(\.string) }
    var timing: JSON? { projectState.timing.truthyValue }
    var lastBuild: BuildRecord? { projectState.lastBuild }
    func stepStatus(_ step: PipelineStepName) -> StepStatus { projectState[step: step]?.status ?? .pending }
    func stepMessage(_ step: PipelineStepName) -> String? { projectState[step: step]?.message }
    func screenState(_ id: String) -> ScreenState? { projectState[screen: id] }
}

/// 单屏视图模型，内部建立在核心库 `ScreenState` 外壳之上。
struct ScreenItem: Identifiable {
    let json: JSON
    init(_ json: JSON) { self.json = json }
    var id: String { json["id"]?.string ?? "" }
    var file: String? { json["file"]?.string }
    var mtime: Double? { json["mtime"]?.number }
    var prompt: String { json["prompt"]?.string ?? "" }
    var state: ScreenState { ScreenState(json["state"] ?? .emptyObject) }
    var gate: JSON? { state.gate.truthyValue }
    var alternates: [JSON] { json["alternates"].items }
    /// 以前用过的截图（新的在前）
    var history: [JSON] { json["history"].items }
    var plan: JSON? { json["plan"].truthyValue }
    var title: String { plan?["title"]?.jsString ?? id }
    var warnings: [String] { ((state.imageWarnings?.items ?? []) + (gate?["warnings"].items ?? [])).map(\.jsString) }
}

// MARK: - 格式化（和 Electron 版界面一致）

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter
}()

/// 10/09 14:05
func formatTime(_ iso: String?) -> String {
    guard let iso, let ms = parseISO(iso) else { return "—" }
    return timeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
}

func formatTime(ms: Double) -> String { timeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000)) }

/// 12.3 秒 / 123 秒
func formatSeconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value >= 100 ? "\(Int(jsRound(value))) 秒" : String(format: "%.1f 秒", value)
}

func formatDurationUI(_ ms: Double?) -> String {
    guard let ms, ms.isFinite else { return "—" }
    return formatDuration(ms)
}

/// 路径里的家目录写成 ~
func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
