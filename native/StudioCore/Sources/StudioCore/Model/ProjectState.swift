/// 项目持久状态。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct ProjectState: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `schemaVersion` 字段。
    public var schemaVersion: Int? {
        get { raw["schemaVersion"]?.int }
        set { raw["schemaVersion"] = newValue.map { JSON($0) } }
    }
    /// 原始 `dir` 字段。
    public var dir: String? {
        get { raw["dir"]?.string }
        set { raw["dir"] = newValue.map(JSON.string) }
    }
    /// 原始 `origin` 字段。
    public var origin: String? {
        get { raw["origin"]?.string }
        set { raw["origin"] = newValue.map(JSON.string) }
    }
    /// 原始 `lastError` 字段。
    public var lastError: String? {
        get { raw["lastError"]?.string }
        set { raw["lastError"] = newValue.map(JSON.string) }
    }
    /// 原始 `screenCountReason` 字段。
    public var screenCountReason: String? {
        get { raw["screenCountReason"]?.string }
        set { raw["screenCountReason"] = newValue.map(JSON.string) }
    }
    /// 原始 `request` 字段。
    public var request: ProjectRequest? {
        get { raw["request"].map(ProjectRequest.init) }
        set { raw["request"] = newValue?.raw }
    }
    /// 原始 `steps` 字段。
    public var steps: JSON? {
        get { raw["steps"] }
        set { raw["steps"] = newValue }
    }
    /// 原始 `screens` 字段。
    public var screens: JSON? {
        get { raw["screens"] }
        set { raw["screens"] = newValue }
    }
    /// 原始 `warnings` 字段。
    public var warnings: JSON? {
        get { raw["warnings"] }
        set { raw["warnings"] = newValue }
    }
    /// 原始 `log` 字段。
    public var log: JSON? {
        get { raw["log"] }
        set { raw["log"] = newValue }
    }
    /// 原始 `timing` 字段。
    public var timing: JSON? {
        get { raw["timing"] }
        set { raw["timing"] = newValue }
    }
    /// 原始 `submitted` 字段。
    public var submitted: JSON? {
        get { raw["submitted"] }
        set { raw["submitted"] = newValue }
    }
    /// 原始 `feedbackPlan` 字段。
    public var feedbackPlan: JSON? {
        get { raw["feedbackPlan"] }
        set { raw["feedbackPlan"] = newValue }
    }
    /// 原始 `appProfile` 字段。
    public var appProfile: JSON? {
        get { raw["appProfile"] }
        set { raw["appProfile"] = newValue }
    }
    /// 原始 `readOnly` 字段。
    public var readOnly: Bool? {
        get { raw["readOnly"]?.bool }
        set { raw["readOnly"] = newValue.map(JSON.bool) }
    }
    /// 原始 `contentDateNeedsRefresh` 字段。
    public var contentDateNeedsRefresh: Bool? {
        get { raw["contentDateNeedsRefresh"]?.bool }
        set { raw["contentDateNeedsRefresh"] = newValue.map(JSON.bool) }
    }
    /// 原始 `overwriteExternalEdits` 字段。
    public var overwriteExternalEdits: Bool? {
        get { raw["overwriteExternalEdits"]?.bool }
        set { raw["overwriteExternalEdits"] = newValue.map(JSON.bool) }
    }
    /// 原始 `lastBuild` 字段。
    public var lastBuild: BuildRecord? {
        get { raw["lastBuild"].map(BuildRecord.init) }
        set { raw["lastBuild"] = newValue?.raw }
    }
    /// 项目状态；未知字符串原样保留。
    public var status: ProjectStatus? {
        get { raw["status"]?.string.map(ProjectStatus.init(rawValue:)) }
        set { raw["status"] = newValue.map { .string($0.rawValue) } }
    }
    /// 意见清单；保留缺失与空数组的区别。
    public var feedback: [FeedbackItem]? {
        get { raw["feedback"]?.array?.map(FeedbackItem.init) }
        set { raw["feedback"] = newValue.map { .array($0.map(\.raw)) } }
    }
    /// 按步骤名访问，更新单项时保留其他步骤和原始顺序。
    public subscript(step name: PipelineStepName) -> StepState? {
        get { raw["steps"]?[name.rawValue].map(StepState.init) }
        set { raw.setChild("steps", name.rawValue, newValue?.raw) }
    }
    /// 按屏编号访问持久状态，不混入界面汇总字段。
    public subscript(screen id: String) -> ScreenState? {
        get { raw["screens"]?[id].map(ScreenState.init) }
        set { raw.setChild("screens", id, newValue?.raw) }
    }
}
