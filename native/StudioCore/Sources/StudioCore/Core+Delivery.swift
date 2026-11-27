import Foundation

extension StudioCore {
    // MARK: - 导出

    public func planExport(_ dirs: [String], targetDir: String, groupName: String = "") throws -> JSON {
        try StudioCore_planExport(dirs: dirs, targetDir: targetDir, projectStore: projectStore, groupName: groupName)
    }

    public func defaultExportGroupName() -> String { defaultGroupName() }

    public func exportBundles(_ dirs: [String], targetDir: String, conflict: String = "skip", groupName: String = "") async throws -> JSON {
        var ready: [String] = []
        var skipped: [JSON] = []
        for dir in dirs {
            do { try await ensureBundleCurrent(dir); ready.append(dir) }
            catch { skipped.append(.obj(["name": .string(Path.basename(dir)), "reason": .string(messageOf(error))])) }
        }
        var result = try StudioCore_exportBundles(dirs: ready, targetDir: targetDir, projectStore: projectStore, conflict: conflict, groupName: groupName, trashItem: trashItem)
        result["skipped"] = .array(result["skipped"].items + skipped)
        try await settingsStore.update { $0.export.lastDir = targetDir }
        return result
    }

    // MARK: - PDF 与字体

    public func fontStatus() async throws -> JSON {
        let settings = try await settingsStore.get()
        let families = installedFontFamilies(refresh: true)
        let plan = resolveFontPlan(settings.pdf, families: families)
        var docs = JSONObject()
        for kind in DOC_FONT_ORDER {
            let doc = DOC_FONTS[kind]!
            docs[kind] = .obj([
                "label": .string(doc.label), "original": .string(doc.original), "installed": .bool(plan[kind]!.mode == "original"),
                "using": .string(plan[kind]!.label), "choice": .string(settings.pdf[kind]),
                "choices": .array(SUBSTITUTE_CHOICES[kind]!.map { .obj(["value": .string($0), "label": .string(SUBSTITUTES[$0]!.label)]) }),
            ])
        }
        return .obj(["detected": .bool(!families.isEmpty), "docs": .object(docs)])
    }

    public func installFonts(_ files: [String]) -> JSON { installFontFiles(files) }

    /// 批量只重导 PDF（一个个来；LibreOffice 本来就排队）。
    public func reexportPdfs(_ dirs: [String]) async -> JSON {
        var done: [JSON] = []
        var failed: [String] = []
        for (index, dir) in dirs.enumerated() {
            emit(.obj(["type": "pdf-reexport", "current": .string(dir), "index": .number(Double(index)), "total": .number(Double(dirs.count))]))
            do {
                let result = try await pipeline.reexportPdfs(dir)
                done.append(.obj(["dir": .string(dir), "warnings": result["warnings"] ?? []]))
            } catch {
                failed.append("\(Path.basename(dir))：\(messageOf(error))")
            }
        }
        emit(.obj(["type": "pdf-reexport", "current": .null, "index": .number(Double(dirs.count)), "total": .number(Double(dirs.count))]))
        return .obj(["done": .array(done), "failed": JSON(failed)])
    }

    public func inspectCodeSource(path: String, extensions: [String]) async throws -> JSON {
        let settings = try await settingsStore.get()
        let result = try collectCodeSource(path: path, extensions: extensions, excludeDirs: settings.codeDefaults.excludeDirs)
        return .obj([
            "fileCount": .number(Double(result.fileCount)), "lineCount": .number(Double(result.lineCount)), "nonEmptyLines": .number(Double(result.nonEmptyLines)),
            "estimatedPages": .number(Double(result.estimatedPages)), "files": JSON(Array(result.files.prefix(50))), "warnings": JSON(result.warnings),
            "wordTemplate": .bool(result.wordTemplate != nil),
        ])
    }

    /// 把一份模板加进模板库并设为默认模板（已在库里的直接设为默认）。
    public func importCodeTemplate(_ path: String) async throws {
        let raw = Path.extname(path).lowercased() == ".doc" ? try await convertDocToDocx(path) : try FS.read(path)
        let template = try CodeWordTemplate(data: raw)
        let results = try await addCodeTemplates([path])
        if let first = results.first, !first["ok"].isTruthy, !first["error"].text.hasPrefix("已经在模板库里了") { throw StudioError(first["error"].text) }
        let library = try await settingsStore.get().codeTemplates
        let id = library.entries.first { $0.id == template.sha256 || $0.sourceSha == sha256Hex(try! FS.read(path)) }?.id ?? template.sha256
        try await updateSettings(["codeSource": ["path": .string(codeTemplateFile(dataDir, id)), "extensions": [".java"]]])
    }

    /// 把交付包打成 zip，放在项目文件夹里。
    public func zipBundle(_ dir: String) async throws -> String {
        try await ensureBundleCurrent(dir)
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        let name = state.request?.softwareName ?? ""
        let bundleDir = projectPaths(dir).bundle(name)
        var zip = ZipWriter()
        zip.addDirectory("\(name)/")
        for file in (FS.list(bundleDir) ?? []).sorted() where !file.hasPrefix(".") {
            zip.addFile("\(name)/\(file)", try FS.read(Path.join(bundleDir, file)))
        }
        let target = Path.join(dir, "\(name).zip")
        try FS.write(target, zip.finish())
        return target
    }

    // MARK: - 批量

    public func batchRemoveProjects(_ dirs: [String]) async {
        let removable: [QueueStatus] = [.queued, .paused, .failed, .needsAttention]
        for item in batch.listTyped().items where dirs.contains(item.projectDir ?? "") && item.status.map(removable.contains) == true {
            await batch.remove(item.id ?? "")
        }
    }

    // MARK: - 记录

    public func queryCalls(limit: Int = 200, providerId: String? = nil) -> [JSON] { callLog.query(limit: limit, providerId: providerId) }
    public func queryLlmCalls(limit: Int = 200) -> [JSON] { llmLog.query(limit: limit) }
    /// 统计页数据；days 为 nil 时统计全部。
    public func usageStats(days: Int?) async throws -> JSON {
        let since = days.map { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Calendar.current.startOfDay(for: Date()))!.timeIntervalSince1970 * 1000 }
        return UsageStats.compute(imageCalls: callLog.all(), llmCalls: llmLog.all(), projects: try await listProjects(), sinceMs: since)
    }
    public func pendingJobs() -> [JSON] {
        ledger.list { raw in
            let job = ImageJob(raw)
            return job.state == "needs-attention" || job.state == "interrupted"
        }
    }
    public func dismissJob(_ jobId: String) async { await ledger.dismiss(jobId) }

    /// 启动时：清理一天前失败构建留下的临时文件夹，续查异步任务，恢复批量队列。
    public func start() async {
        do {
            let recovered = try await recoverCodeTemplateTransactions()
            if !recovered.isEmpty { emit(.obj(["type": "project", "recovered": JSON(recovered)])) }
        } catch {
            emit(.obj(["type": "startup-error", "message": .string("代码模板中断恢复未完成，自动任务未启动：\(messageOf(error))")]))
            return
        }
        let stagingRoot = projectStore.stagingRoot
        for name in FS.list(stagingRoot) ?? [] {
            let target = Path.join(stagingRoot, name)
            if let mtime = FS.mtimeMs(target), nowMs() - mtime > 86_400_000 { FS.remove(target) }
        }
        _ = await gateway.resumePending()
        await batch.initialize()
        // 上次关软件前已经手动处理完的项目
        let projectStore = self.projectStore
        await batch.settle { dir in (try? projectStore.readTyped(dir))?.status?.rawValue }
        for entry in readIndex()["projects"].items {
            if let dir = entry["dir"]?.string { await pipeline.scheduleBundleUpdate(dir) }
        }
    }
}

// 和同名方法区分开的自由函数别名
func StudioCore_planExport(dirs: [String], targetDir: String, projectStore: ProjectStore, groupName: String) throws -> JSON {
    try planExport(dirs: dirs, targetDir: targetDir, projectStore: projectStore, groupName: groupName)
}
func StudioCore_exportBundles(dirs: [String], targetDir: String, projectStore: ProjectStore, conflict: String, groupName: String, trashItem: @escaping @Sendable (String) throws -> Void) throws -> JSON {
    try exportBundles(dirs: dirs, targetDir: targetDir, projectStore: projectStore, conflict: conflict, groupName: groupName, trashItem: trashItem)
}
