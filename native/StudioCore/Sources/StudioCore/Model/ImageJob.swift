/// 生图任务账本条目。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct ImageJob: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `jobId` 字段。
    public var jobId: String? {
        get { raw["jobId"]?.string }
        set { raw["jobId"] = newValue.map(JSON.string) }
    }
    /// 原始 `projectDir` 字段。
    public var projectDir: String? {
        get { raw["projectDir"]?.string }
        set { raw["projectDir"] = newValue.map(JSON.string) }
    }
    /// 原始 `screenId` 字段。
    public var screenId: String? {
        get { raw["screenId"]?.string }
        set { raw["screenId"] = newValue.map(JSON.string) }
    }
    /// 原始 `outputPath` 字段。
    public var outputPath: String? {
        get { raw["outputPath"]?.string }
        set { raw["outputPath"] = newValue.map(JSON.string) }
    }
    /// 原始 `alternatesDir` 字段。
    public var alternatesDir: String? {
        get { raw["alternatesDir"]?.string }
        set { raw["alternatesDir"] = newValue.map(JSON.string) }
    }
    /// 原始 `archiveRoot` 字段。
    public var archiveRoot: String? {
        get { raw["archiveRoot"]?.string }
        set { raw["archiveRoot"] = newValue.map(JSON.string) }
    }
    /// 原始 `prompt` 字段。
    public var prompt: String? {
        get { raw["prompt"]?.string }
        set { raw["prompt"] = newValue.map(JSON.string) }
    }
    /// 原始 `batchId` 字段。
    public var batchId: String? {
        get { raw["batchId"]?.string }
        set { raw["batchId"] = newValue.map(JSON.string) }
    }
    /// 原始 `state` 字段。
    public var state: String? {
        get { raw["state"]?.string }
        set { raw["state"] = newValue.map(JSON.string) }
    }
    /// 原始 `createdAt` 字段。
    public var createdAt: String? {
        get { raw["createdAt"]?.string }
        set { raw["createdAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `updatedAt` 字段。
    public var updatedAt: String? {
        get { raw["updatedAt"]?.string }
        set { raw["updatedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `winnerAttemptId` 字段。
    public var winnerAttemptId: String? {
        get { raw["winnerAttemptId"]?.string }
        set { raw["winnerAttemptId"] = newValue.map(JSON.string) }
    }
    /// 原始 `providerId` 字段。
    public var providerId: String? {
        get { raw["providerId"]?.string }
        set { raw["providerId"] = newValue.map(JSON.string) }
    }
    /// 原始 `error` 字段。
    public var error: String? {
        get { raw["error"]?.string }
        set { raw["error"] = newValue.map(JSON.string) }
    }
    /// 原始 `attempts` 字段。
    public var attempts: [ImageAttempt]? {
        get { raw["attempts"]?.array?.map(ImageAttempt.init) }
        set { raw["attempts"] = newValue.map { .array($0.map(\.raw)) } }
    }
}
