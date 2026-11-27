import Foundation

extension StudioCore {
    // MARK: - 项目

    public func listProjects() async throws -> [JSON] {
        ListPerformance.begin()
        let started = ListPerformance.now
        defer { ListPerformance.finish(since: started) }
        let index = readIndex()
        let settings = try await settingsStore.get()
        let queueByDir = queueIndex()
        let entries = index["projects"].items
        let batches = projectBatches(entries)
        return entries.compactMap { entry in
            guard var summary = summarize(entry, settings, queueByDir) else { return nil }
            if let batch = batches[entry["dir"]?.string ?? ""] { summary["batch"] = batch }
            return summary
        }
    }

    public func getProgress(_ dir: String) -> JSON? { pipeline.getProgress(dir) }
    public func stepEstimates() -> [String: Double] { pipeline.stepEstimates() }

    public func getProject(_ dir: String) async throws -> JSON {
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        let plan = try? readPlan(dir)
        let content = FS.readJSONQuiet(projectPaths(dir).content)
        let paths = projectPaths(dir)
        var ids: [String] = []
        if let plan = plan ?? nil {
            ids = plan["screens"].items.map { $0["id"]?.jsString ?? "" }
        } else {
            ids = (content?["screens"].items ?? []).enumerated().map { $0.element["id"].or(.string(screenId($0.offset))).jsString }
        }
        var screens: [JSON] = []
        for id in ids {
            let file = paths.screenFile(id)
            let mtime = FS.mtimeMs(file)
            screens.append(.obj([
                "id": .string(id),
                "file": mtime != nil ? .string(file) : .null,
                "mtime": JSON.orNull(mtime),
                "prompt": .string(FS.readTextIfExists(paths.promptFile(id)) ?? ""),
                "state": state[screen: id]?.raw ?? .emptyObject,
                "alternates": .array(listAlternates(dir, id)),
                "history": .array(screenHistory(dir, id)),
                "plan": (plan ?? nil)?["screens"].items.first { $0["id"]?.string == id } ?? .null,
            ]))
        }
        let name = state.request?.softwareName ?? ""
        let bundleDir = paths.bundle(name)
        let bundleFiles = (FS.list(bundleDir) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let settings = try await settingsStore.get()
        let code = codeSourceFor(state, settings)
        return .obj([
            "dir": .string(dir), "state": state.raw.merging(.obj(["bundleUpdating": .bool(pipeline.bundleActive.current.contains(dir))])), "plan": (plan ?? nil) ?? .null, "content": content ?? .null, "screens": .array(screens),
            "bundleDir": .string(bundleDir), "bundleFiles": JSON(bundleFiles), "running": .bool(pipeline.isForegroundRunning(dir)), "progress": pipeline.getProgress(dir) ?? .null,
            "codeSource": .obj([
                "source": code.source ?? .null, "locked": .bool(code.locked), "global": settings.codeSource.path.isEmpty ? .null : settings.codeSource.json,
                "templateId": JSON.orNull(settings.codeTemplates.entry(forPath: code.source?["path"]?.string ?? "")?.id),
                "templateLabel": JSON.orNull(settings.codeTemplates.entry(forPath: code.source?["path"]?.string ?? "")?.label),
            ]),
            "contentHistory": .array(contentHistory(dir)),
            "externalEdits": JSON(externallyEditedFiles(dir, state)),
        ])
    }

    /// request：{ softwareName, screenCount, emphasis, notes, platform, wantDesign, versionPolicy?, workspaceDir? }
    public func createProject(_ request: JSON) async throws -> String {
        let settings = try await settingsStore.get()
        let req = ProjectRequest(request)
        let softwareName = (req.softwareName ?? "").jsTrimmed
        try assertSafeSoftwareName(softwareName)
        let workspace = request["workspaceDir"].truthyValue?.jsString ?? settings.workspaceDir
        let dir = Path.join(workspace, softwareName)
        if projectStore.exists(dir) { throw StudioError("已经有「\(softwareName)」这个项目了，可以在项目列表里找到它") }
        if FS.exists(dir), inspectProject(dir) != nil { throw StudioError("工作区里已经有「\(softwareName)」这个项目，请用「导入历史项目」或换个名字") }
        let contentDate = (req.contentDate ?? "").jsTrimmed
        if !contentDate.isEmpty && !validContentDate(contentDate) { throw StudioError("内容日期请填写有效的 YYYY-MM-DD 日期") }
        let earliestDate = (req.earliestDate ?? "").jsTrimmed
        if !earliestDate.isEmpty && !validContentDate(earliestDate) { throw StudioError("最早日期请填写有效的 YYYY-MM-DD 日期，或留空") }
        if !earliestDate.isEmpty, earliestDate > (contentDate.isEmpty ? localDateKey() : contentDate) { throw StudioError("最早日期不能晚于内容日期") }
        try FS.mkdirp(dir)
        // 代码模板：指定了就用指定的，否则按模板库的分配规则（默认轮流平均分）
        try? await migrateCodeTemplateLibrary()
        let library = try await settingsStore.get().codeTemplates
        var codeSource: JSON = .null
        if !library.enabled.isEmpty {
            let wanted = request["codeTemplateId"]?.string ?? ""
            let entry: CodeTemplateEntry?
            if let chosen = library.entry(wanted), chosen.enabled { entry = chosen }
            else {
                var usage = codeTemplateUsage(library, try await settingsStore.get())
                entry = library.pick(&usage)
            }
            if let entry { codeSource = codeSourceJSON(dataDir, entry) }
        }
        // 版本号自动判断
        let versionPolicy = req.versionPolicy == "separate-metadata" ? "separate-metadata" : detectVersion(softwareName) != nil ? "in-name" : "none"
        var fields = req
        fields.softwareName = softwareName
        fields.versionPolicy = versionPolicy
        fields.codeSource = codeSource
        fields.raw["codeTemplateId"] = nil
        if !codeSource.isNull { fields.codeSourceLocked = true }
        fields.raw["workspaceDir"] = nil
        fields.contentDate = contentDate.isEmpty ? localDateKey() : contentDate
        fields.earliestDate = earliestDate
        fields.createdAt = (req.createdAt?.isEmpty == false ? req.createdAt : nil) ?? localDateKey()
        // 1.6.0 起新建的项目：生图提示词加内容红线（旧项目不加，免得截图全部重生）
        fields.policyVersion = 2
        let state = ProjectState(newState(fields.raw))
        try await projectStore.writeTyped(dir, state)
        let addedAt = isoNow()
        try await updateIndex { projects in
            if !projects.contains(where: { $0["dir"]?.string == dir }) { projects.insert(.obj(["dir": .string(dir), "addedAt": .string(addedAt), "origin": "created"]), at: 0) }
        }
        return dir
    }

    /// 批量新建：每行一个软件名，可选用逗号带上 截图数、重点功能、补充说明。
    /// codeTemplateId：全部用这个模板；不填按模板库的分配规则，一批里也保持平均。
    /// regenerate：已经做过、要重新生成的软件名（新建前用 nameConflicts 查出来，由用户确认）。
    /// 这些项目沿用原来的文件夹，旧文件先归档，再全部重做；不在 regenerate 里的同名项目跳过。
    public func createProjectsFromList(_ text: String, screenCount: Int?, platform: String, wantDesign: Bool, contentDate: String = "", earliestDate: String = "", codeTemplateId: String? = nil, regenerate: Set<String> = []) async throws -> (created: [String], regenerated: [String], errors: [String]) {
        if !contentDate.isEmpty && !validContentDate(contentDate) { throw StudioError("内容日期请填写有效的 YYYY-MM-DD 日期") }
        if !earliestDate.isEmpty && !validContentDate(earliestDate) { throw StudioError("最早日期请填写有效的 YYYY-MM-DD 日期，或留空") }
        let rows = parseBatchList(text)
        if rows.isEmpty { throw StudioError("没有读到软件名（每行一个）") }
        var created: [String] = []
        var regenerated: [String] = []
        var errors: [String] = []
        var seen = Set<String>()
        try? await migrateCodeTemplateLibrary()
        let settings = try await settingsStore.get()
        var library = settings.codeTemplates
        if let codeTemplateId, library.entry(codeTemplateId)?.enabled == true { library.assign = "fixed"; library.fixedId = codeTemplateId }
        var usage = codeTemplateUsage(library, settings)
        for row in rows {
            do {
                if seen.contains(row.softwareName) { throw StudioError("列表里重复了，只做一次") }
                seen.insert(row.softwareName)
                let request: JSON = .obj([
                    "softwareName": .string(row.softwareName), "screenCount": JSON.orNull(row.screenCount ?? screenCount), "emphasis": .string(row.emphasis),
                    "notes": .string(row.notes), "platform": .string(platform), "wantDesign": .bool(wantDesign),
                    "contentDate": .string(contentDate), "earliestDate": .string(earliestDate),
                ])
                let existing = Path.join(settings.workspaceDir, row.softwareName)
                if projectStore.exists(existing) {
                    guard regenerate.contains(row.softwareName) else { throw StudioError("已经做过，已跳过") }
                    try await regenerateProject(existing, request)
                    regenerated.append(existing)
                    continue
                }
                let dir = try await createProject(.obj([
                    "softwareName": .string(row.softwareName), "screenCount": JSON.orNull(row.screenCount ?? screenCount), "emphasis": .string(row.emphasis),
                    "notes": .string(row.notes), "platform": .string(platform), "wantDesign": .bool(wantDesign),
                    "contentDate": .string(contentDate), "earliestDate": .string(earliestDate),
                    "codeTemplateId": JSON.orNull(library.pick(&usage)?.id),
                ]))
                created.append(dir)
            } catch {
                errors.append("\(row.softwareName)：\(messageOf(error))")
            }
        }
        // 记下批次，历史项目里可以按批次一次选中
        if created.count > 1 {
            let batchId = "batch-\(randomHex(4))"
            let members = Set(created)
            try await updateIndex { projects in
                for index in projects.indices where members.contains(projects[index]["dir"]?.string ?? "") {
                    projects[index]["batchId"] = .string(batchId)
                }
            }
        }
        return (created, regenerated, errors)
    }

    /// 新建前查同名：每个软件名在工作区里是不是已经有项目，能不能重新生成。
    /// 返回有冲突的那些：{ name, dir, kind: project|folder, canRegenerate, reason, lastBuildAt }
    public func nameConflicts(_ names: [String]) async throws -> [JSON] {
        let workspace = try await settingsStore.get().workspaceDir
        let busy = Set(batch.listTyped().items.filter { $0.status == .queued || $0.status == .paused || $0.status == .running }.compactMap(\.projectDir))
        var result: [JSON] = []
        for name in uniqued(names.map(\.jsTrimmed).filter { !$0.isEmpty }) {
            let dir = Path.join(workspace, name)
            if let state = try? projectStore.readTyped(dir) {
                let reason: String? = isSubmitted(state) ? "已提交，只读"
                    : pipeline.isRunning(dir) || busy.contains(dir) ? "正在运行或排队"
                    : nil
                result.append(.obj([
                    "name": .string(name), "dir": .string(dir), "kind": "project", "canRegenerate": .bool(reason == nil),
                    "reason": JSON.orNull(reason), "lastBuildAt": state.lastBuild?.at.map(JSON.string) ?? .null,
                ]))
            } else if FS.exists(dir), inspectProject(dir) != nil {
                result.append(.obj(["name": .string(name), "dir": .string(dir), "kind": "folder", "canRegenerate": false, "reason": "工作区里有这个文件夹，但不在项目列表里，可以先用「导入历史项目」"]))
            }
        }
        return result
    }

    /// 整个重新生成：沿用项目原来的屏数、重点、补充说明、平台和最早日期，内容日期按今天。
    public func regenerateProject(_ dir: String) async throws {
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        let request = state.request
        try await regenerateProject(dir, .obj([
            "screenCount": JSON.orNull(request?.screenCount), "emphasis": .string(request?.emphasis ?? ""), "notes": .string(request?.notes ?? ""),
            "platform": .string(request?.platform ?? ""), "wantDesign": .bool(request?.wantDesign == true), "contentDate": "", "earliestDate": .string(request?.earliestDate ?? ""),
        ]))
    }

    /// 重新生成一个已经做过的项目：旧的规划、截图、提示词、说明先归档，按这次填的设置从头重做。
    /// 代码来源保持原样；交付包在重新出包时按原来的规则自动归档。已提交或正在运行的不能重新生成。
    public func regenerateProject(_ dir: String, _ request: JSON) async throws {
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        try assertNotSubmitted(state)
        let queued = batch.listTyped().items.contains { $0.projectDir == dir && ($0.status == .queued || $0.status == .paused || $0.status == .running) }
        if pipeline.isRunning(dir) || queued { throw StudioError("正在运行或排队，不能重新生成") }
        let reqInput = ProjectRequest(request)
        let contentDate = (reqInput.contentDate ?? "").jsTrimmed
        if !contentDate.isEmpty && !validContentDate(contentDate) { throw StudioError("内容日期请填写有效的 YYYY-MM-DD 日期") }
        let earliestDate = (reqInput.earliestDate ?? "").jsTrimmed
        if !earliestDate.isEmpty && !validContentDate(earliestDate) { throw StudioError("最早日期请填写有效的 YYYY-MM-DD 日期，或留空") }
        if !earliestDate.isEmpty, earliestDate > (contentDate.isEmpty ? localDateKey() : contentDate) { throw StudioError("最早日期不能晚于内容日期") }

        let paths = projectPaths(dir)
        let archive = Path.join(paths.archive, "重新生成前-\(timestampSlug())")
        let keep = [paths.screenPlan, paths.featureMap, paths.profile, paths.uiContract, paths.content, paths.regionIndex, paths.screens, paths.prompts]
        let existing = keep.filter(FS.exists)
        if !existing.isEmpty {
            try FS.mkdirp(archive)
            for path in existing { try FS.copy(path, Path.join(archive, Path.basename(path))) }
        }
        try await projectStore.updateTyped(dir) { state in
            var req = state.request ?? ProjectRequest(.emptyObject)
            if let count = reqInput.screenCount, count != 0 { req.screenCount = count } else { req.raw["screenCount"] = .null }
            req.emphasis = reqInput.emphasis ?? ""
            req.notes = reqInput.notes ?? ""
            req.platform = reqInput.platform ?? ""
            req.wantDesign = reqInput.wantDesign ?? false
            req.contentDate = contentDate.isEmpty ? localDateKey() : contentDate
            req.earliestDate = earliestDate
            req.policyVersion = max(req.policyVersion ?? 0, 2)
            state.request = req
            appendLog(&state, existing.isEmpty ? "重新生成：从头再做" : "重新生成：旧的规划、截图、说明已归档到 archive/\(Path.basename(archive))，从头再做")
        }
        await batch.enqueue([dir], name: "重新生成", mode: "redo")
        emit(.obj(["type": "project", "projectDir": .string(dir)]))
    }

    /// 标记或取消「已提交」。已提交的项目只读，批量操作自动跳过。正在运行或排队的不能标记。
    public func setSubmitted(_ dirs: [String], _ submitted: Bool) async throws -> (changed: [String], skipped: [String]) {
        var changed: [String] = []
        var skipped: [String] = []
        let queued = Set(batch.listTyped().items.filter { $0.status == .queued || $0.status == .paused || $0.status == .running }.compactMap(\.projectDir))
        let at = isoNow()
        for dir in uniqued(dirs) {
            if submitted, pipeline.isRunning(dir) || queued.contains(dir) {
                skipped.append("\(Path.basename(dir))：正在运行或排队")
                continue
            }
            guard projectStore.exists(dir) else { skipped.append("\(Path.basename(dir))：项目不存在"); continue }
            try await projectStore.updateTyped(dir) { state in
                state.submitted = submitted ? .obj(["at": .string(at)]) : nil
                appendLog(&state, submitted ? "标记为已提交（只读）" : "取消已提交")
            }
            changed.append(dir)
            emit(.obj(["type": "project", "projectDir": .string(dir)]))
        }
        return (changed, skipped)
    }

    /// 从列表移除。deleteFolder 为 true 时连项目文件夹一起移到废纸篓（可以从废纸篓恢复）。
    public func removeFromList(_ dir: String, deleteFolder: Bool = false) async throws {
        if pipeline.isRunning(dir) { throw StudioError("项目正在运行，先停止") }
        if deleteFolder, FS.exists(dir) {
            let settings = try await settingsStore.get()
            let target = Path.resolve(dir)
            // 只读项目（比如 skill 自带的示例）的文件夹不是这个软件的，不删
            let current = try? projectStore.readTyped(dir)
            if current?.readOnly == true { throw StudioError("只读项目的文件夹不能删除，只能从列表移除") }
            if isSubmitted(current) { throw StudioError("已提交的项目文件夹不能删除，只能从列表移除；要删除请先取消已提交") }
            // 防止误删工作区、主目录这类上层文件夹，以及不像项目的文件夹
            let protected = [settings.workspaceDir, NSHomeDirectory(), Path.join(NSHomeDirectory(), "Desktop"), Path.join(NSHomeDirectory(), "Documents"), Path.join(NSHomeDirectory(), "Downloads"), "/"].map(Path.resolve)
            let markers = ["content.json", "screen-plan.json", "project-manifest.json", "generation-record.json", "screens"]
            // 工作区里直接的子文件夹（包括刚建、还空着的）可以删；工作区以外的必须看得出是项目文件夹
            let insideWorkspace = Path.dirname(target) == Path.resolve(settings.workspaceDir)
            if protected.contains(target) || Path.basename(target).isEmpty || !(insideWorkspace || markers.contains(where: { FS.exists(Path.join(target, $0)) })) {
                throw StudioError("这个文件夹看起来不是项目文件夹，没有删除：\(dir)")
            }
            try trashItem(target)
        }
        for item in batch.listTyped().items where item.projectDir == dir {
            await batch.remove(item.id ?? "")
        }
        try await updateIndex { $0.removeAll { $0["dir"]?.string == dir } }
        await projectStore.remove(dir)
    }

    public func scanWorkspace(_ workspaceDir: String? = nil) async throws -> [JSON] {
        let settings = try await settingsStore.get()
        let store = projectStore
        return try StudioCore_scanWorkspace(workspaceDir ?? settings.workspaceDir) { store.exists($0) }
    }

    public func importProjects(_ dirs: [String]) async throws -> (imported: [String], failed: [String]) {
        var imported: [String] = []
        var failed: [String] = []
        for dir in dirs {
            do {
                if projectStore.exists(dir) { continue }
                guard let info = inspectProject(dir) else { throw StudioError("不是项目文件夹") }
                let state = ProjectState(try createImportedState(dir, info))
                try await projectStore.writeTyped(dir, state)
                if state.readOnly != true { try await pipeline.adoptImported(dir) }
                let addedAt = isoNow()
                try await updateIndex { projects in
                    if !projects.contains(where: { $0["dir"]?.string == dir }) { projects.append(.obj(["dir": .string(dir), "addedAt": .string(addedAt), "origin": "imported"])) }
                }
                imported.append(dir)
            } catch {
                failed.append("\(Path.basename(dir))：\(messageOf(error))")
            }
        }
        return (imported, failed)
    }

    public func renameSoftware(_ dir: String, _ newName: String) async throws -> String {
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        try assertNotSubmitted(state)
        let name = newName.jsTrimmed
        try assertSafeSoftwareName(name)
        if pipeline.isRunning(dir) { throw StudioError("项目正在运行，先停止") }
        if batch.listTyped().items.contains(where: { $0.projectDir == dir && ($0.status == .queued || $0.status == .running) }) {
            throw StudioError("项目还在批量队列里，先从队列移除再改名")
        }
        let oldName = state.request?.softwareName ?? ""
        if oldName == name { return dir }
        try await pipeline.updateRequest(dir, .obj(["softwareName": .string(name)]))
        // 文件夹名和软件名一致时，一并改名
        var finalDir = dir
        if Path.basename(dir) == oldName {
            let target = Path.join(Path.dirname(dir), name)
            if !FS.exists(target) {
                try FS.move(dir, target)
                try projectStore.move(dir, target)
                try await updateIndex { projects in
                    projects = projects.map { $0["dir"]?.string == dir ? $0.merging(.obj(["dir": .string(target)])) : $0 }
                }
                finalDir = target
            }
        }
        return finalDir
    }

    @discardableResult
    public func run(_ dir: String, _ options: RunOptions = RunOptions()) -> Task<RunResult, Never> {
        let task = pipeline.start(dir, options)
        return task
    }

    public func cancel(_ dir: String) { pipeline.cancel(dir) }
}

// 和同名方法区分开的自由函数别名
func StudioCore_scanWorkspace(_ dir: String, isManaged: (String) -> Bool) throws -> [JSON] { try scanWorkspace(dir, isManaged: isManaged) }
