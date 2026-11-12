/// 上次交付记录。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct BuildRecord: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `at` 字段。
    public var at: String? {
        get { raw["at"]?.string }
        set { raw["at"] = newValue.map(JSON.string) }
    }
    /// 原始 `bundleDir` 字段。
    public var bundleDir: String? {
        get { raw["bundleDir"]?.string }
        set { raw["bundleDir"] = newValue.map(JSON.string) }
    }
    /// 原始 `codeSha256` 字段。
    public var codeSha256: String? {
        get { raw["codeSha256"]?.string }
        set { raw["codeSha256"] = newValue.map(JSON.string) }
    }
    /// 原始 `pdfPages` 字段。
    public var pdfPages: Int? {
        get { raw["pdfPages"]?.int }
        set { raw["pdfPages"] = newValue.map { JSON($0) } }
    }
    /// 原始 `codePdfPages` 字段。
    public var codePdfPages: Int? {
        get { raw["codePdfPages"]?.int }
        set { raw["codePdfPages"] = newValue.map { JSON($0) } }
    }
    /// 原始 `withPdf` 字段。
    public var withPdf: Bool? {
        get { raw["withPdf"]?.bool }
        set { raw["withPdf"] = newValue.map(JSON.bool) }
    }
    /// 原始 `withCode` 字段。
    public var withCode: Bool? {
        get { raw["withCode"]?.bool }
        set { raw["withCode"] = newValue.map(JSON.bool) }
    }
    /// 原始 `bundleHashes` 字段。
    public var bundleHashes: JSON? {
        get { raw["bundleHashes"] }
        set { raw["bundleHashes"] = newValue }
    }
    /// 原始 `files` 字段。
    public var files: JSON? {
        get { raw["files"] }
        set { raw["files"] = newValue }
    }
    /// 原始 `code` 字段。
    public var code: JSON? {
        get { raw["code"] }
        set { raw["code"] = newValue }
    }
    /// 原始 `pdfFonts` 字段。
    public var pdfFonts: JSON? {
        get { raw["pdfFonts"] }
        set { raw["pdfFonts"] = newValue }
    }
    /// 原始 `warnings` 字段。
    public var warnings: JSON? {
        get { raw["warnings"] }
        set { raw["warnings"] = newValue }
    }
}
