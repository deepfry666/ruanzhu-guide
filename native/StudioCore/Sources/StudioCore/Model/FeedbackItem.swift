/// 持久化修改意见。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct FeedbackItem: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `id` 字段。
    public var id: String? {
        get { raw["id"]?.string }
        set { raw["id"] = newValue.map(JSON.string) }
    }
    /// 原始 `text` 字段。
    public var text: String? {
        get { raw["text"]?.string }
        set { raw["text"] = newValue.map(JSON.string) }
    }
    /// 原始 `at` 字段。
    public var at: String? {
        get { raw["at"]?.string }
        set { raw["at"] = newValue.map(JSON.string) }
    }
    /// 原始 `status` 字段。
    public var status: String? {
        get { raw["status"]?.string }
        set { raw["status"] = newValue.map(JSON.string) }
    }
    /// 原始 `target` 字段。
    public var target: String? {
        get { raw["target"]?.string }
        set { raw["target"] = newValue.map(JSON.string) }
    }
    /// 原始 `doneAt` 字段。
    public var doneAt: String? {
        get { raw["doneAt"]?.string }
        set { raw["doneAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `appliedAs` 字段。
    public var appliedAs: String? {
        get { raw["appliedAs"]?.string }
        set { raw["appliedAs"] = newValue.map(JSON.string) }
    }
}
