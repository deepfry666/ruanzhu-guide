/// 列表首图的临时摘要，只包含路径和修改时间，不改变项目持久格式。
public struct ProjectThumbnail: Sendable, Hashable {
    public let path: String
    public let modifiedAt: Double

    public init?(raw: JSON?) {
        guard let path = raw?["path"]?.string, let modifiedAt = raw?["modifiedAt"]?.number else { return nil }
        self.path = path
        self.modifiedAt = modifiedAt
    }

    public var raw: JSON { .obj(["path": .string(path), "modifiedAt": .number(modifiedAt)]) }

    /// 由后台列表摘要调用；不读取规划正文或解码图片。
    public static func read(dir: String, state: ProjectState) -> ProjectThumbnail? {
        let id = state.screens?.fields.keys.sorted().first ?? screenId(0)
        let path = projectPaths(dir).screenFile(id)
        guard let stamp = FS.mtimeMs(path) else { return nil }
        return ProjectThumbnail(raw: .obj(["path": .string(path), "modifiedAt": .number(stamp)]))
    }
}
