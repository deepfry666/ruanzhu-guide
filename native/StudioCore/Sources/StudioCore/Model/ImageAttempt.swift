/// 生图任务的一次尝试。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct ImageAttempt: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `attemptId` 字段。
    public var attemptId: String? {
        get { raw["attemptId"]?.string }
        set { raw["attemptId"] = newValue.map(JSON.string) }
    }
    /// 原始 `providerId` 字段。
    public var providerId: String? {
        get { raw["providerId"]?.string }
        set { raw["providerId"] = newValue.map(JSON.string) }
    }
    /// 原始 `model` 字段。
    public var model: String? {
        get { raw["model"]?.string }
        set { raw["model"] = newValue.map(JSON.string) }
    }
    /// 原始 `role` 字段。
    public var role: String? {
        get { raw["role"]?.string }
        set { raw["role"] = newValue.map(JSON.string) }
    }
    /// 原始 `requestSize` 字段。
    public var requestSize: String? {
        get { raw["requestSize"]?.string }
        set { raw["requestSize"] = newValue.map(JSON.string) }
    }
    /// 原始 `state` 字段。
    public var state: String? {
        get { raw["state"]?.string }
        set { raw["state"] = newValue.map(JSON.string) }
    }
    /// 原始 `startedAt` 字段。
    public var startedAt: String? {
        get { raw["startedAt"]?.string }
        set { raw["startedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `taskId` 字段。
    public var taskId: String? {
        get { raw["taskId"]?.string }
        set { raw["taskId"] = newValue.map(JSON.string) }
    }
    /// 原始 `endedAt` 字段。
    public var endedAt: String? {
        get { raw["endedAt"]?.string }
        set { raw["endedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `outcome` 字段。
    public var outcome: String? {
        get { raw["outcome"]?.string }
        set { raw["outcome"] = newValue.map(JSON.string) }
    }
    /// 原始 `alternatePath` 字段。
    public var alternatePath: String? {
        get { raw["alternatePath"]?.string }
        set { raw["alternatePath"] = newValue.map(JSON.string) }
    }
    /// 原始 `error` 字段。
    public var error: String? {
        get { raw["error"]?.string }
        set { raw["error"] = newValue.map(JSON.string) }
    }
    /// 原始 `kind` 字段。
    public var kind: String? {
        get { raw["kind"]?.string }
        set { raw["kind"] = newValue.map(JSON.string) }
    }
    /// 原始 `resumed` 字段。
    public var resumed: Bool? {
        get { raw["resumed"]?.bool }
        set { raw["resumed"] = newValue.map(JSON.bool) }
    }
}
