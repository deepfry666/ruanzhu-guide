import Foundation

/// 只供试用包使用；在任何核心服务创建前完成验证和副本准备。
public enum TrialData {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func validate(_ destination: String) throws {
        let target = canonical(destination)
        let source = canonical(nativeDataDir())
        let support = canonical(Path.dirname(nativeDataDir()))
        let settings = try FS.readJSON(Path.join(source, "settings.json")) ?? .emptyObject
        let workspace = canonical(settings["workspaceDir"]?.string ?? Settings().workspaceDir)
        guard Path.dirname(target) == support, Path.basename(target).contains("试用"),
              !Path.isInside(source, target), !Path.isInside(target, source),
              !Path.isInside(workspace, target), !Path.isInside(target, workspace) else {
            throw StudioError("试用数据目录必须是应用程序支持下独立的试用文件夹，不能与正式数据或工作区重叠")
        }
        // 禁止已有副本通过符号链接把后续写操作引向正式数据。
        try rejectLinks(destination)
    }

    private static func rejectLinks(_ path: String) throws {
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink {
            throw StudioError("试用副本不接受符号链接")
        }
        if let walker = fm.enumerator(atPath: path) {
            for case let relative as String in walker {
                if (try fm.attributesOfItem(atPath: Path.join(path, relative))[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw StudioError("试用副本不接受符号链接")
                }
            }
        }
    }

    public static func prepare(_ destination: String, measure: Bool, reset: Bool, count: Int, selected: [String]) throws {
        try validate(destination)
        let marker = Path.join(destination, "trial-mode.json")
        if FS.exists(destination) {
            guard let mode = try FS.readJSON(marker), mode["measure"]?.bool == measure else {
                throw StudioError("试用目录缺少匹配的模式标记；请换一个 --name")
            }
            if !reset {
                guard mode["ready"]?.bool == true else { throw StudioError("上次试用准备未完成，请使用 --reset 重试") }
                let saved = try FS.readJSON(Path.join(destination, "settings.json"))
                guard saved?["workspaceDir"]?.string == Path.join(destination, "workspace") else {
                    throw StudioError("试用工作区已改变，请使用 --reset 重建")
                }
                return
            }
            try FileManager.default.removeItem(atPath: destination)
        }
        let source = nativeDataDir()
        let workspace = Path.join(destination, "workspace")
        var settings = try FS.readJSON(Path.join(source, "settings.json")) ?? .emptyObject
        let oldWorkspace = settings["workspaceDir"]?.string ?? Settings().workspaceDir
        let entries = (try FS.readJSON(Path.join(source, "projects-index.json")))?["projects"].items ?? []
        let store = ProjectStore(dataDir: source)
        let available = try entries.compactMap { entry -> (JSON, ProjectState)? in
            guard let dir = entry["dir"]?.string, let state = try store.readTyped(dir) else { return nil }
            return (entry, state)
        }
        let chosen: [(JSON, ProjectState)]
        if measure { chosen = available }
        else if !selected.isEmpty {
            chosen = available.filter { row in selected.contains { canonical($0) == canonical(row.0["dir"]!.text) } }
            guard chosen.count == Set(selected.map(canonical)).count else { throw StudioError("指定项目未在正式索引中找到") }
        } else {
            chosen = Array(available.filter { $0.1.status == .done }.sorted {
                ($0.1.lastBuild?.at ?? $0.0["addedAt"].text) > ($1.1.lastBuild?.at ?? $1.0["addedAt"].text)
            }.prefix(count))
        }
        // 先写归属标记，失败副本可以安全 reset，但不能作为完整数据复用。
        try FS.mkdirp(workspace)
        try FS.writeJSONAtomic(marker, ["measure": .bool(measure), "ready": false])
        var mappings = [(source, destination), (oldWorkspace, workspace)]
        for (entry, _) in chosen {
            let old = entry["dir"]!.text
            mappings.append((old, Path.join(workspace, projectKey(old), Path.basename(old))))
        }
        mappings.sort { $0.0.count > $1.0.count }
        func rewrite(_ value: JSON) -> JSON {
            if let text = value.string {
                for (old, new) in mappings where text == old || text.hasPrefix(old + "/") {
                    return .string(new + text.dropFirst(old.count))
                }
                return value
            }
            if value.isArray { return .array(value.items.map(rewrite)) }
            if value.isObject {
                var result = JSONObject()
                for (key, child) in value.fields { result[key] = rewrite(child) }
                return .object(result)
            }
            return value
        }
        if !measure {
            for file in ["code-templates", "secrets.json", "secrets.key"] where FS.exists(Path.join(source, file)) {
                try rejectLinks(Path.join(source, file))
                try FileManager.default.copyItem(atPath: Path.join(source, file), toPath: Path.join(destination, file))
            }
            guard FS.exists(Path.join(source, "secrets.json")) == FS.exists(Path.join(source, "secrets.key")) else {
                throw StudioError("正式密钥文件不成对，无法准备试用副本")
            }
        }
        settings = measure ? .emptyObject : rewrite(settings)
        settings["workspaceDir"] = .string(workspace)
        settings.mergeChild("export", "lastDir", .string(workspace))
        try FS.writeJSONAtomic(Path.join(destination, "settings.json"), settings)
        var index: [JSON] = []
        for (entry, state) in chosen {
            let old = entry["dir"]!.text
            let new = rewrite(.string(old)).text
            if !measure {
                try rejectLinks(old)
                try FS.mkdirp(Path.dirname(new))
                try FileManager.default.copyItem(atPath: old, toPath: new)
            } else {
                // 测量模式只放空文件夹：列表走真实的读取路径，项目不显示成「文件夹不见了」，正式项目内容一样不碰
                try FS.mkdirp(new)
            }
            let next = rewrite(state.raw)
            try FS.writeJSONAtomic(Path.join(destination, "projects", "\(projectKey(new)).json"), next)
            index.append(rewrite(entry))
        }
        try FS.writeJSONAtomic(Path.join(destination, "projects-index.json"), ["projects": .array(index)])
        try FS.writeJSONAtomic(marker, ["measure": .bool(measure), "ready": true])
    }
}
