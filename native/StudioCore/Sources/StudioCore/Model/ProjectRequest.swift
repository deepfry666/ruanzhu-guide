/// 项目请求信息。仅保存原始 JSON，读取不补默认值；nil 写入会移除字段。
public struct ProjectRequest: Sendable, Hashable {
    /// 保序的原始数据，包含未知字段。
    public var raw: JSON
    /// 包装原始数据，不做迁移或规范化。
    public init(_ raw: JSON) { self.raw = raw }
    /// 原始 `softwareName` 字段。
    public var softwareName: String? {
        get { raw["softwareName"]?.string }
        set { raw["softwareName"] = newValue.map(JSON.string) }
    }
    /// 原始 `versionPolicy` 字段。
    public var versionPolicy: String? {
        get { raw["versionPolicy"]?.string }
        set { raw["versionPolicy"] = newValue.map(JSON.string) }
    }
    /// 原始 `applicableVersion` 字段。
    public var applicableVersion: String? {
        get { raw["applicableVersion"]?.string }
        set { raw["applicableVersion"] = newValue.map(JSON.string) }
    }
    /// 原始 `emphasis` 字段。
    public var emphasis: String? {
        get { raw["emphasis"]?.string }
        set { raw["emphasis"] = newValue.map(JSON.string) }
    }
    /// 原始 `notes` 字段。
    public var notes: String? {
        get { raw["notes"]?.string }
        set { raw["notes"] = newValue.map(JSON.string) }
    }
    /// 原始 `platform` 字段。
    public var platform: String? {
        get { raw["platform"]?.string }
        set { raw["platform"] = newValue.map(JSON.string) }
    }
    /// 原始 `compileDate` 字段。
    public var compileDate: String? {
        get { raw["compileDate"]?.string }
        set { raw["compileDate"] = newValue.map(JSON.string) }
    }
    /// 原始 `createdAt` 字段。
    public var createdAt: String? {
        get { raw["createdAt"]?.string }
        set { raw["createdAt"] = newValue.map(JSON.string) }
    }
    /// 原始 `contentDate` 字段。
    public var contentDate: String? {
        get { raw["contentDate"]?.string }
        set { raw["contentDate"] = newValue.map(JSON.string) }
    }
    /// 原始 `earliestDate` 字段。
    public var earliestDate: String? {
        get { raw["earliestDate"]?.string }
        set { raw["earliestDate"] = newValue.map(JSON.string) }
    }
    /// 原始 `screenCount` 字段。
    public var screenCount: Int? {
        get { raw["screenCount"]?.int }
        set { raw["screenCount"] = newValue.map { JSON($0) } }
    }
    /// 原始 `policyVersion` 字段。
    public var policyVersion: Int? {
        get { raw["policyVersion"]?.int }
        set { raw["policyVersion"] = newValue.map { JSON($0) } }
    }
    /// 原始 `wantDesign` 字段。
    public var wantDesign: Bool? {
        get { raw["wantDesign"]?.bool }
        set { raw["wantDesign"] = newValue.map(JSON.bool) }
    }
    /// 原始 `codeSourceLocked` 字段。
    public var codeSourceLocked: Bool? {
        get { raw["codeSourceLocked"]?.bool }
        set { raw["codeSourceLocked"] = newValue.map(JSON.bool) }
    }
    /// 原始 `codeSource` 字段。
    public var codeSource: JSON? {
        get { raw["codeSource"] }
        set { raw["codeSource"] = newValue }
    }
    /// 原始 `txtFields` 字段。
    public var txtFields: JSON? {
        get { raw["txtFields"] }
        set { raw["txtFields"] = newValue }
    }
    /// 原始 `extraBrandTokens` 字段。
    public var extraBrandTokens: JSON? {
        get { raw["extraBrandTokens"] }
        set { raw["extraBrandTokens"] = newValue }
    }
}
