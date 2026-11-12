/// 每屏持久状态。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct ScreenState: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `promptHash` 字段。
    public var promptHash: String? {
        get { raw["promptHash"]?.string }
        set { raw["promptHash"] = newValue.map(JSON.string) }
    }
    /// 原始 `imagePromptHash` 字段。
    public var imagePromptHash: String? {
        get { raw["imagePromptHash"]?.string }
        set { raw["imagePromptHash"] = newValue.map(JSON.string) }
    }
    /// 原始 `imageSha` 字段。
    public var imageSha: String? {
        get { raw["imageSha"]?.string }
        set { raw["imageSha"] = newValue.map(JSON.string) }
    }
    /// 原始 `providerId` 字段。
    public var providerId: String? {
        get { raw["providerId"]?.string }
        set { raw["providerId"] = newValue.map(JSON.string) }
    }
    /// 原始 `providerName` 字段。
    public var providerName: String? {
        get { raw["providerName"]?.string }
        set { raw["providerName"] = newValue.map(JSON.string) }
    }
    /// 原始 `model` 字段。
    public var model: String? {
        get { raw["model"]?.string }
        set { raw["model"] = newValue.map(JSON.string) }
    }
    /// 原始 `requestSize` 字段。
    public var requestSize: String? {
        get { raw["requestSize"]?.string }
        set { raw["requestSize"] = newValue.map(JSON.string) }
    }
    /// 原始 `generatedAt` 字段。
    public var generatedAt: String? {
        get { raw["generatedAt"]?.string }
        set { raw["generatedAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `contentHash` 字段。
    public var contentHash: String? {
        get { raw["contentHash"]?.string }
        set { raw["contentHash"] = newValue.map(JSON.string) }
    }
    /// 原始 `requestedChange` 字段。
    public var requestedChange: String? {
        get { raw["requestedChange"]?.string }
        set { raw["requestedChange"] = newValue.map(JSON.string) }
    }
    /// 原始 `width` 字段。
    public var width: Int? {
        get { raw["width"]?.int }
        set { raw["width"] = newValue.map { JSON($0) } }
    }
    /// 原始 `height` 字段。
    public var height: Int? {
        get { raw["height"]?.int }
        set { raw["height"] = newValue.map { JSON($0) } }
    }
    /// 原始 `promptEdited` 字段。
    public var promptEdited: Bool? {
        get { raw["promptEdited"]?.bool }
        set { raw["promptEdited"] = newValue.map(JSON.bool) }
    }
    /// 原始 `textEdited` 字段。
    public var textEdited: Bool? {
        get { raw["textEdited"]?.bool }
        set { raw["textEdited"] = newValue.map(JSON.bool) }
    }
    /// 原始 `contentStale` 字段。
    public var contentStale: Bool? {
        get { raw["contentStale"]?.bool }
        set { raw["contentStale"] = newValue.map(JSON.bool) }
    }
    /// 原始 `hedged` 字段。
    public var hedged: Bool? {
        get { raw["hedged"]?.bool }
        set { raw["hedged"] = newValue.map(JSON.bool) }
    }
    /// 原始 `fromAlternate` 字段。
    public var fromAlternate: Bool? {
        get { raw["fromAlternate"]?.bool }
        set { raw["fromAlternate"] = newValue.map(JSON.bool) }
    }
    /// 原始 `gate` 字段。
    public var gate: JSON? {
        get { raw["gate"] }
        set { raw["gate"] = newValue }
    }
    /// 原始 `imageWarnings` 字段。
    public var imageWarnings: JSON? {
        get { raw["imageWarnings"] }
        set { raw["imageWarnings"] = newValue }
    }
}
