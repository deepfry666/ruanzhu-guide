/// 单个步骤状态。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct StepState: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `startedAt` 字段。
    public var startedAt: String? {
        get { raw["startedAt"]?.string }
        set { raw["startedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `finishedAt` 字段。
    public var finishedAt: String? {
        get { raw["finishedAt"]?.string }
        set { raw["finishedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `inputHash` 字段。
    public var inputHash: String? {
        get { raw["inputHash"]?.string }
        set { raw["inputHash"] = newValue.map(JSON.string) }
    }
    /// 原始 `error` 字段。
    public var error: String? {
        get { raw["error"]?.string }
        set { raw["error"] = newValue.map(JSON.string) }
    }
    /// 原始 `message` 字段。
    public var message: String? {
        get { raw["message"]?.string }
        set { raw["message"] = newValue.map(JSON.string) }
    }
    /// 步骤状态；未知字符串原样保留。
    public var status: StepStatus? {
        get { raw["status"]?.string.map(StepStatus.init(rawValue:)) }
        set { raw["status"] = newValue.map { .string($0.rawValue) } }
    }
}
