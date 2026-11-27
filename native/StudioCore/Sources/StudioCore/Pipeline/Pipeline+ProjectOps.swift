import Foundation

extension Pipeline {
    /// 批量队列里每个项目怎么跑。
    /// continue：从停下的地方继续或更新；rewrite：截图不动，所有说明和封面介绍按现在的规则重写；
    /// redo：全部重做（重新规划、出图、写文字、出交付包），人工改过的文字也重写。
    func batchRunOptions(_ dir: String, _ mode: String) async throws -> RunOptions {
        switch mode {
        case "feedback":
            // 批量修改：按项目里已经整理、确认好的修改意见改
            let actions = try readTypedState(dir).feedbackPlan?["actions"].items ?? []
            if actions.isEmpty { throw StudioError("没有整理好的修改意见") }
            let prepared = try await prepareFeedback(dir, actions: actions, reviewPlan: false)
            return prepared.options ?? RunOptions(reviewPlan: false, reason: "修改意见")
        case "rewrite", "redo":
            try assertEditable(dir)
            let ids = (try readPlan(dir))?["screens"].items.compactMap { $0["id"]?.string } ?? []
            if mode == "rewrite", ids.isEmpty { throw StudioError("还没有界面规划，不能只重写文字；可以选「全部重做」") }
            try await updateState(dir) { state in
                for id in ids {
                    guard var shot = state[screen: id] else { continue }
                    shot.textEdited = false
                    if mode == "redo" { shot.promptEdited = false }
                    state[screen: id] = shot
                }
                state.overviewEdited = false
                appendLog(&state, mode == "redo" ? "批量：全部重做" : "批量：只重写文字")
            }
            return mode == "redo"
                // 全部重做：规划强制重来；截图也全部重新生成（新规划和旧的一样时也不沿用旧图）
                ? RunOptions(from: PipelineStepName.plan.rawValue, force: [PipelineStepName.plan.rawValue], forceScreens: (0..<20).map(screenId), reviewPlan: false, reason: "全部重做")
                : RunOptions(from: PipelineStepName.content.rawValue, forceContent: ids + ["overview"], reviewPlan: false, reason: "只重写文字")
        default:
            return RunOptions(reviewPlan: false)
        }
    }

    public func rewriteContent(_ dir: String, _ ids: [String]) async throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        for id in ids where id != "overview" { try assertScreenId(id) }
        try await updateState(dir) { state in
            for id in ids {
                guard var shot = state[screen: id] else { continue }
                shot.textEdited = false
                state[screen: id] = shot
            }
            if ids.contains("overview") { state.overviewEdited = false }
        }
        return start(dir, RunOptions(from: PipelineStepName.content.rawValue, forceContent: ids))
    }

    @discardableResult
    public func updateRequest(_ dir: String, _ patch: JSON) async throws -> JSON {
        try assertEditable(dir)
        if isForegroundRunning(dir) { try assertIdle(dir) }
        let state = try readTypedState(dir)
        let before = state.request ?? ProjectRequest(.emptyObject)
        var patchReq = ProjectRequest(patch)
        if let date = patchReq.contentDate {
            let value = date.jsTrimmed
            if !value.isEmpty && !validContentDate(value) { throw StudioError("内容日期请填写有效的 YYYY-MM-DD 日期") }
            patchReq.contentDate = value.isEmpty ? localDateKey() : value
        }
        if let date = patchReq.earliestDate {
            let value = date.jsTrimmed
            if !value.isEmpty && !validContentDate(value) { throw StudioError("最早日期请填写有效的 YYYY-MM-DD 日期，或留空") }
            patchReq.earliestDate = value
        }
        let nextContentDate = patchReq.contentDate ?? before.contentDate ?? ""
        let nextEarliest = patchReq.earliestDate ?? before.earliestDate ?? ""
        if validContentDate(nextContentDate), validContentDate(nextEarliest), nextEarliest > nextContentDate {
            throw StudioError("最早日期（\(nextEarliest)）不能晚于内容日期（\(nextContentDate)）")
        }
        var next = ProjectRequest(before.raw.merging(patchReq.raw))
        // 版本号不用人选：按软件名自动判断（历史项目里单独填适用版本的保持不变）
        if let name = patchReq.softwareName, before.versionPolicy != "separate-metadata" {
            next.versionPolicy = detectVersion(name) != nil ? "in-name" : "none"
        }
        var dirty = Set<String>()
        func changed(_ key: String) -> Bool {
            guard let value = patchReq.raw[key] else { return false }
            return value.serialized() != (before.raw[key] ?? .null).serialized()
        }
        func orNull(_ value: JSON?) -> JSON { value.truthyValue ?? .null }
        if let name = patchReq.softwareName, name != before.softwareName {
            let paths = projectPaths(dir)
            let oldName = before.softwareName ?? ""
            let oldBundle = paths.bundle(oldName)
            if FS.isDirectory(oldBundle) {
                try FS.mkdirp(paths.archive)
                try FS.move(oldBundle, Path.join(paths.archive, "\(oldName)-交付-\(timestampSlug())"))
            }
            [PipelineStepName.prompts, .gate, .receipt, .build].forEach { dirty.insert($0.rawValue) }
        }
        if ["screenCount", "emphasis", "notes", "platform", "contentDate", "earliestDate"].contains(where: { changed($0) && orNull(patchReq.raw[$0]) != orNull(before.raw[$0]) }) {
            [PipelineStepName.plan, .prompts, .images, .gate, .content, .receipt, .build].forEach { dirty.insert($0.rawValue) }
        }
        if changed("contentDate") || changed("earliestDate") { dirty.insert(PipelineStepName.design.rawValue) }
        if changed("wantDesign"), (patchReq.wantDesign == true) != (before.wantDesign == true) { [PipelineStepName.design, .receipt, .build].forEach { dirty.insert($0.rawValue) } }
        if ["codeSource", "codeSourceLocked", "txtFields", "compileDate", "versionPolicy", "applicableVersion", "allowDropCodeDoc"].contains(where: changed) { dirty.insert(PipelineStepName.build.rawValue) }
        if changed("extraBrandTokens") { [PipelineStepName.gate, .receipt, .build].forEach { dirty.insert($0.rawValue) } }
        let request = next
        let refreshContentDate = dirty.contains(PipelineStepName.plan.rawValue) && (patchReq.contentDate != nil || patchReq.earliestDate != nil)
        try await updateState(dir) { draft in
            draft.request = request
            if refreshContentDate { draft.contentDateNeedsRefresh = true }
            appendLog(&draft, "项目设置已更新")
        }
        try await markDirty(dir, PIPELINE_STEPS.filter { dirty.contains($0) })
        return try readTypedState(dir).raw
    }

    /// 历史项目没有代码来源时：改用总设置里的代码来源（下次生成交付包时生效）。
    public func useGlobalCodeSource(_ dir: String) async throws {
        try assertEditable(dir)
        try assertIdle(dir)
        let settings = try await settingsStore.get()
        if settings.codeSource.path.isEmpty { throw StudioError("总设置里还没有代码来源，先到「设置 → 代码来源」里选择") }
        let extensions = settings.codeSource.extensions.isEmpty ? [".java"] : settings.codeSource.extensions
        try await updateRequest(dir, .obj(["codeSource": .obj(["path": .string(settings.codeSource.path), "extensions": JSON(extensions)]), "codeSourceLocked": true]))
    }

    /// 忽略「PDF 字体不对」：人工看过 PDF 觉得可以接受，就不再标红（不改动任何文件）。
    public func ignorePdfFontWarning(_ dir: String) async throws {
        try assertIdle(dir)
        _ = try await updateState(dir) { draft in
            guard var lastBuild = draft.lastBuild, lastBuild.raw.truthy else { return }
            var fonts = lastBuild.pdfFonts.or(.emptyObject)
            var ignored: [String] = []
            for (kind, entry) in fonts.fields where entry.isObject && entry["ok"] == .bool(false) {
                fonts[kind] = entry.merging(["ok": true, "ignored": true])
                ignored.append(kind)
            }
            guard !ignored.isEmpty else { return }
            lastBuild.pdfFonts = fonts
            lastBuild.warnings = .array(lastBuild.warnings.items.filter { !$0.jsString.contains("PDF 字体不对") })
            draft.lastBuild = lastBuild
            appendLog(&draft, "已忽略 PDF 字体提示（\(ignored.map { DOC_FONTS[$0]?.label ?? $0 }.joined(separator: "、"))）", "info")
        }
    }

    /// 重新导出PDF；旧指南图片超宽时先用已有内容重排Word，TXT和截图不动。
    public func reexportPdfs(_ dir: String) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let handle = RunHandle(cancellable: false)
        let job = Task<JSON, Error> {
            guard let state = try self.projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
            let settings = try await self.settingsStore.get()
            let fontPlan = resolveFontPlan(settings.pdf)
            let result = try await reexportBundlePdfs(projectDir: dir, softwareName: self.softwareName(state), stagingRoot: self.projectStore.stagingRoot, fontPlan: fontPlan) { message in
                try? await self.log(dir, message)
            }
            let report = BuildRecord(result)
            let warnings = report.warnings.items.map(\.jsString)
            let at = isoNow()
            try await self.updateState(dir) { draft in
                if var lastBuild = draft.lastBuild, lastBuild.raw.truthy {
                    // 重排指南 Word 是软件自己改的，更新指纹，免得下次误以为是在软件外改的
                    if result["guideLayoutRepaired"].isTruthy {
                        let name = draft.request?.softwareName ?? ""
                        lastBuild.bundleHashes = refreshBundleHashes(lastBuild, dir, name, files: ["\(name)指南.docx"])
                    }
                    lastBuild.pdfFonts = lastBuild.pdfFonts.or(.emptyObject).merging(report.pdfFonts)
                    if let pages = report.pdfPages { lastBuild.pdfPages = pages } else { lastBuild.raw["pdfPages"] = report.raw["pdfPages"] }
                    if let pages = report.codePdfPages { lastBuild.codePdfPages = pages } else { lastBuild.raw["codePdfPages"] = report.raw["codePdfPages"] }
                    lastBuild.withPdf = true
                    lastBuild.warnings = .array(lastBuild.warnings.items.filter { !$0.jsString.contains("PDF 字体不对") } + report.warnings.items)
                    draft.lastBuild = lastBuild
                }
                draft.pdfReexportedAt = at
                appendLog(&draft, "已重新导出 PDF：\(jsJoin(report.files.items, "、"))\(warnings.isEmpty ? "" : "（\(warnings.joined(separator: "；"))）")", warnings.isEmpty ? "info" : "warn")
            }
            try await updateRecord(dir) { record in
                record.append("history", .obj(["at": .string(isoNow()), "event": "pdf-reexported", "files": report.files, "pdfFonts": report.pdfFonts, "pdfPages": report.pdfPages.map { JSON($0) }, "codePdfPages": report.codePdfPages.map { JSON($0) }]))
            }
            return result
        }
        handle.task = Task { _ = try? await job.value; return RunResult(status: ProjectStatus.done.rawValue) }
        running.withLock { $0[dir] = handle }
        emit(.obj(["type": "project", "projectDir": .string(dir), "status": .string(ProjectStatus.running.rawValue)]))
        defer {
            running.withLock { if $0[dir] === handle { $0[dir] = nil } }
            emit(.obj(["type": "project", "projectDir": .string(dir)]))
        }
        return try await job.value
    }

    /// 导入的历史项目：沿用原有提示词、截图和验收回执，算好各步骤的输入哈希，
    /// 避免第一次运行时把已有截图当成「过期」而重新生成。
    public func adoptImported(_ dir: String) async throws {
        let settings = try await settingsStore.get()
        let paths = projectPaths(dir)
        let plan = try readPlan(dir)
        var state = try readTypedState(dir)
        let platform = platformOf(state, settings)
        if let plan {
            let ui = normalizedUi(plan)
            struct AdoptPatch: Sendable {
                let rowHash: String
                let identity: String?
                let edited: Bool
            }
            var patches: [String: AdoptPatch] = [:]
            var order: [String] = []
            let name = softwareName(state)
            for screen in plan["screens"].items {
                let id = screen["id"]?.jsString ?? ""
                let prompt = FS.readTextIfExists(paths.promptFile(id))
                let identity = prompt.map { promptIdentity($0, name) }
                if patches[id] == nil { order.append(id) }
                patches[id] = AdoptPatch(rowHash: planRowHash(screen, ui, platform, settings.image.targetSize), identity: identity, edited: prompt != nil)
            }
            let all = patches
            let ids = order
            try await updateState(dir) { draft in
                for id in ids {
                    guard let patch = all[id] else { continue }
                    var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                    shot.planRowHash = patch.rowHash
                    shot.setPromptHashOrNull(patch.identity)
                    shot.setImagePromptHashOrNull(patch.identity)
                    shot.promptEdited = patch.edited
                    draft[screen: id] = shot
                }
                draft.promptsName = draft.request?.softwareName
            }
        }
        state = try readTypedState(dir)
        var hashes: [(PipelineStepName, String)] = []
        for step in [PipelineStepName.plan, .prompts, .build] where state[step: step]?.status == .done {
            if let hash = stepInputHash(step, dir, state, settings) { hashes.append((step, hash)) }
        }
        let computed = hashes
        try await updateState(dir) { draft in
            for (step, hash) in computed {
                var entry = draft[step: step] ?? StepState(.emptyObject)
                entry.inputHash = hash
                draft[step: step] = entry
            }
        }
    }
}
