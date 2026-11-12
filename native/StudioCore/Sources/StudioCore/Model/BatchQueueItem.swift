/// 批量队列条目。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct BatchQueueItem: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `id` 字段。
    public var id: String? {
        get { raw["id"]?.string }
        set { raw["id"] = newValue.map(JSON.string) }
    }
    /// 原始 `projectDir` 字段。
    public var projectDir: String? {
        get { raw["projectDir"]?.string }
        set { raw["projectDir"] = newValue.map(JSON.string) }
    }
    /// 原始 `batchId` 字段。
    public var batchId: String? {
        get { raw["batchId"]?.string }
        set { raw["batchId"] = newValue.map(JSON.string) }
    }
    /// 原始 `batchName` 字段。
    public var batchName: String? {
        get { raw["batchName"]?.string }
        set { raw["batchName"] = newValue.map(JSON.string) }
    }
    /// 原始 `mode` 字段。
    public var mode: String? {
        get { raw["mode"]?.string }
        set { raw["mode"] = newValue.map(JSON.string) }
    }
    /// 原始 `addedAt` 字段。
    public var addedAt: String? {
        get { raw["addedAt"]?.string }
        set { raw["addedAt"] = newValue.map(JSON.string) }
    }
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
    /// 原始 `error` 字段。
    public var error: String? {
        get { raw["error"]?.string }
        set { raw["error"] = newValue.map(JSON.string) }
    }
    /// 队列状态；未知字符串原样保留。
    public var status: QueueStatus? {
        get { raw["status"]?.string.map(QueueStatus.init(rawValue:)) }
        set { raw["status"] = newValue.map { .string($0.rawValue) } }
    }
}
