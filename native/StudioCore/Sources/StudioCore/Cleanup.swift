import Foundation

// MARK: - 清理空间
//
// 设置里的「清理空间」：先扫描、按类列出能腾出多少空间，用户勾选后才清理；清理一律移到废纸篓，从不直接删除。
//
// 第一档（默认勾选，对成果没有影响，当前版本也不读取这些文件夹）：
//   · 各已登记项目里的 tmp、scripts、lib、tests、debug
//   · 工作区根目录下旧流程遗留的文件夹（只认 node_modules、tmp、tools，且里面没有 screens 和项目状态文件）
// 第二档（默认不勾选）：各项目 archive 里超过 30 天的「旧截图」和「手改保留的旧文件」。
//
// 永远不碰：screens、各 json、prompts、交付文件夹和 zip、30 天内的 archive、没有登记的项目文件夹、软件数据目录。
// 运行中、排队中的项目整个跳过；只读项目（不是本软件的文件夹）整个跳过；已提交的项目不清理第二档。

public let CLEANUP_PROJECT_DIRS = ["tmp", "scripts", "lib", "tests", "debug"]
public let CLEANUP_WORKSPACE_DIRS = ["node_modules", "tmp", "tools"]
public let CLEANUP_ARCHIVE_DAYS = 30

/// 工作区旧文件夹里出现这些就说明可能是项目，整个文件夹不列出。
private let CLEANUP_PROJECT_MARKER_FILES: Set<String> = ["project-manifest.json", "screen-plan.json", "content.json", "software-profile.json", "feature-map.json"]
private let CLEANUP_PROJECT_MARKER_DIRS: Set<String> = ["screens", "prompts", "archive"]

public enum CleanupKind: String, Sendable, CaseIterable {
    /// 项目里的 tmp、scripts、lib、tests、debug
    case projectTemp
    /// 工作区根目录下的旧流程文件夹
    case workspaceLeftover
    /// archive 里 30 天前的旧截图（screens-*）
    case oldScreens
    /// archive 里 30 天前的手改保留（*-手改保留-*）
    case oldHandEdits

    /// 第一档默认勾选，第二档不勾选。
    public var defaultChecked: Bool { self == .projectTemp || self == .workspaceLeftover }
    public var tier: Int { defaultChecked ? 1 : 2 }
}

public struct CleanupItem: Sendable, Hashable, Identifiable {
    public let path: String
    public let kind: CleanupKind
    /// 所属项目；工作区旧文件夹没有
    public let projectDir: String?
    public let projectName: String?
    public let bytes: Int
    public var id: String { path }
    public var name: String { Path.basename(path) }
}

/// 界面上的一行：项目临时文件夹合成一行，工作区旧文件夹每个一行，旧截图、手改保留各一行。
public struct CleanupGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: CleanupKind
    public let items: [CleanupItem]
    public var bytes: Int { items.reduce(0) { $0 + $1.bytes } }
    public var projectCount: Int { Set(items.compactMap(\.projectDir)).count }
}

public struct CleanupScan: Sendable {
    public var groups: [CleanupGroup] = []
    /// 因为正在运行或排队而整个跳过的项目数
    public var busyProjects = 0
    public var items: [CleanupItem] { groups.flatMap(\.items) }
}

public struct CleanupFailure: Sendable {
    public let item: CleanupItem
    public let message: String
}

public struct CleanupResult: Sendable {
    public var trashed: [CleanupItem] = []
    public var failed: [CleanupFailure] = []
    /// 最新扫描里已经没有、或项目刚开始运行而跳过的路径
    public var skipped: [String] = []
    public var bytes: Int { trashed.reduce(0) { $0 + $1.bytes } }
}

/// 扫描输入里的一个项目（状态由核心库读好，扫描本身只看文件）
struct CleanupProject: Sendable {
    let dir: String
    let name: String
    let softwareName: String
    let busy: Bool
    let readOnly: Bool
    let submitted: Bool
    let codeSource: String?
}

struct CleanupTree {
    var bytes = 0
    var newestMs = 0.0
    var hasProjectMarkers = false
}

private func normalizedPath(_ path: String) -> String { Path.resolve(path).precomposedStringWithCanonicalMapping }

/// 真的是文件夹（符号链接不算，也不跟进去）
private func isRealDirectory(_ path: String) -> Bool {
    (try? FS.fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
}

/// 递归统计占用空间和最新修改时间；符号链接只记它自己，不跟进去。
func cleanupWalk(_ path: String) -> CleanupTree {
    var tree = CleanupTree()
    tree.newestMs = FS.mtimeMs(path) ?? 0
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    guard let walker = FS.fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: []) else { return tree }
    for case let url as URL in walker {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if let date = values.contentModificationDate { tree.newestMs = max(tree.newestMs, date.timeIntervalSince1970 * 1000) }
        if values.isSymbolicLink == true { continue }
        let name = url.lastPathComponent
        if values.isDirectory == true {
            if CLEANUP_PROJECT_MARKER_DIRS.contains(name) { tree.hasProjectMarkers = true }
        } else {
            if CLEANUP_PROJECT_MARKER_FILES.contains(name) { tree.hasProjectMarkers = true }
            if values.isRegularFile == true { tree.bytes += values.totalFileAllocatedSize ?? 0 }
        }
    }
    return tree
}

/// 归档文件夹名里的时间：screens-2026-10-16T03-16-44-480Z、xxx-手改保留-2026-10-16T03-16-44-480Z → 毫秒
func archiveNameMs(_ name: String) -> Double? {
    guard let groups = Rx.match(#"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})"#, name) else { return nil }
    return parseISO("\(groups[1] ?? "")-\(groups[2] ?? "")-\(groups[3] ?? "")T\(groups[4] ?? ""):\(groups[5] ?? ""):00Z")
}

/// 只看文件系统的扫描器：输入已经读好，方便单独检查规则。
struct CleanupScanner: Sendable {
    let workspaceDir: String
    let projects: [CleanupProject]
    let globalCodeSource: String
    let nowMs: Double

    func run() -> CleanupScan {
        var scan = CleanupScan()
        scan.busyProjects = projects.filter(\.busy).count
        var temp: [CleanupItem] = []
        var screens: [CleanupItem] = []
        var edits: [CleanupItem] = []
        for project in projects where !project.busy && !project.readOnly && FS.exists(project.dir) {
            temp += projectTemp(project)
            if !project.submitted {
                let (oldScreens, oldEdits) = oldArchive(project)
                screens += oldScreens
                edits += oldEdits
            }
        }
        if !temp.isEmpty { scan.groups.append(CleanupGroup(id: CleanupKind.projectTemp.rawValue, kind: .projectTemp, items: temp)) }
        for item in workspaceLeftover() { scan.groups.append(CleanupGroup(id: "workspace:\(item.path)", kind: .workspaceLeftover, items: [item])) }
        if !screens.isEmpty { scan.groups.append(CleanupGroup(id: CleanupKind.oldScreens.rawValue, kind: .oldScreens, items: screens)) }
        if !edits.isEmpty { scan.groups.append(CleanupGroup(id: CleanupKind.oldHandEdits.rawValue, kind: .oldHandEdits, items: edits)) }
        return scan
    }

    /// 项目里的 tmp、scripts、lib、tests、debug。交付文件夹和代码来源所在的文件夹不碰（即使重名）。
    private func projectTemp(_ project: CleanupProject) -> [CleanupItem] {
        let children = Set(FS.list(project.dir) ?? [])
        let bundle = normalizedPath(projectPaths(project.dir).bundle(project.softwareName))
        return CLEANUP_PROJECT_DIRS.compactMap { name in
            let path = Path.join(project.dir, name)
            guard children.contains(name), isRealDirectory(path), normalizedPath(path) != bundle, !overlapsCodeSource(path, project) else { return nil }
            return CleanupItem(path: path, kind: .projectTemp, projectDir: project.dir, projectName: project.name, bytes: cleanupWalk(path).bytes)
        }
    }

    /// archive 里超过 30 天的 screens-*（旧截图）和 *-手改保留-*。
    /// 文件夹名里的时间和里面文件最新的修改时间都超过 30 天才算；名字里读不出时间的一律不列。
    private func oldArchive(_ project: CleanupProject) -> ([CleanupItem], [CleanupItem]) {
        let archive = projectPaths(project.dir).archive
        guard isRealDirectory(archive) else { return ([], []) }
        let cutoff = nowMs - Double(CLEANUP_ARCHIVE_DAYS) * 86_400_000
        var screens: [CleanupItem] = []
        var edits: [CleanupItem] = []
        for name in (FS.list(archive) ?? []).sorted() {
            let isScreens = name.hasPrefix("screens-")
            let isEdits = name.contains("-手改保留-")
            let path = Path.join(archive, name)
            guard isScreens || isEdits, isRealDirectory(path), let named = archiveNameMs(name), named < cutoff else { continue }
            let tree = cleanupWalk(path)
            guard tree.newestMs < cutoff else { continue }
            let item = CleanupItem(path: path, kind: isScreens ? .oldScreens : .oldHandEdits, projectDir: project.dir, projectName: project.name, bytes: tree.bytes)
            if isScreens { screens.append(item) } else { edits.append(item) }
        }
        return (screens, edits)
    }

    /// 工作区根目录下的旧流程文件夹。只认固定名单；是已登记项目、含已登记项目、含 screens 或项目状态文件、
    /// 是符号链接、盖住了代码来源的，一律不列。
    private func workspaceLeftover() -> [CleanupItem] {
        let root = normalizedPath(workspaceDir)
        guard !workspaceDir.isEmpty, root != "/", let children = FS.list(workspaceDir).map(Set.init) else { return [] }
        let registered = projects.map { normalizedPath($0.dir) }
        return CLEANUP_WORKSPACE_DIRS.compactMap { name in
            let path = Path.join(workspaceDir, name)
            let normalized = normalizedPath(path)
            guard children.contains(name), isRealDirectory(path), Path.dirname(normalized) == root else { return nil }
            guard !registered.contains(where: { Path.isInside(normalized, $0) }) else { return nil }
            guard !overlaps(path, globalCodeSource), !projects.contains(where: { overlaps(path, $0.codeSource ?? "") }) else { return nil }
            let tree = cleanupWalk(path)
            guard !tree.hasProjectMarkers else { return nil }
            return CleanupItem(path: path, kind: .workspaceLeftover, projectDir: nil, projectName: nil, bytes: tree.bytes)
        }
    }

    private func overlaps(_ path: String, _ source: String) -> Bool {
        guard !source.isEmpty else { return false }
        let a = normalizedPath(path)
        let b = normalizedPath(source)
        return Path.isInside(a, b) || Path.isInside(b, a)
    }

    private func overlapsCodeSource(_ path: String, _ project: CleanupProject) -> Bool {
        overlaps(path, globalCodeSource) || overlaps(path, project.codeSource ?? "")
    }
}

extension StudioCore {
    /// 正在运行或在批量队列里（排队、暂停、运行中）的项目
    func busyProjectDirs() -> Set<String> {
        let active: [QueueStatus] = [.queued, .paused, .running]
        let queued = batch.list().items.map(BatchQueueItem.init).filter { item in item.status.map(active.contains) ?? false }
        return Set(queued.compactMap(\.projectDir))
    }

    /// 扫描能清理什么（只读文件，不改任何东西）。
    public func scanCleanup(now: Date = Date()) async throws -> CleanupScan {
        let settings = try await settingsStore.get()
        let busy = busyProjectDirs()
        let projects: [CleanupProject] = readIndex()["projects"].items.compactMap { entry in
            guard let dir = entry["dir"]?.string, let json = try? projectStore.read(dir) else { return nil }
            let state = ProjectState(json)
            let name = state.request?.softwareName ?? ""
            return CleanupProject(
                dir: dir, name: name.isEmpty ? Path.basename(dir) : name, softwareName: name,
                busy: busy.contains(dir) || pipeline.isRunning(dir), readOnly: state.readOnly == true,
                submitted: isSubmitted(state.raw), codeSource: state.request?.codeSource?["path"]?.string
            )
        }
        let scanner = CleanupScanner(workspaceDir: settings.workspaceDir, projects: projects, globalCodeSource: settings.codeSource.path, nowMs: now.timeIntervalSince1970 * 1000)
        return await Task.detached { scanner.run() }.value
    }

    /// 把勾选的内容移到废纸篓。路径只当作「选了哪几项」，真正要清理的以现在重新扫描的结果为准：
    /// 不在扫描结果里的路径一律不动；动手前项目刚开始运行也跳过。
    public func runCleanup(_ paths: [String]) async throws -> CleanupResult {
        let wanted = Set(paths)
        let fresh = try await scanCleanup()
        let known = fresh.items
        var result = CleanupResult()
        result.skipped = paths.filter { path in !known.contains { $0.path == path } }
        let trash = trashItem
        let pipeline = pipeline
        for item in known where wanted.contains(item.path) {
            if let dir = item.projectDir, pipeline.isRunning(dir) || busyProjectDirs().contains(dir) {
                result.skipped.append(item.path)
                continue
            }
            do {
                try await Task.detached { try trash(item.path) }.value
                result.trashed.append(item)
            } catch {
                result.failed.append(CleanupFailure(item: item, message: messageOf(error)))
            }
        }
        return result
    }
}
