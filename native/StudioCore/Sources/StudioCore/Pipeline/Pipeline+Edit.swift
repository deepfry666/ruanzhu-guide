import Foundation

extension Pipeline {
    // MARK: - 编辑操作

    func markDirty(_ dir: String, _ steps: [String]) async throws {
        try await updateState(dir) { state in
            for step in steps {
                let name = PipelineStepName(rawValue: step)
                guard var entry = state[step: name] else { continue }
                entry.status = .pending
                entry.clearInputHash()
                state[step: name] = entry
            }
            state.bundleRevision = (state.bundleRevision ?? 0) + 1
            state.bundleUpdateError = nil
            state.bundleUpdateNotice = nil
            if state.status == .done, !self.onlyLocalStepsRemain(state) { state.status = .idle }
        }
        await scheduleBundleUpdate(dir)
    }

    func assertScreenId(_ id: String) throws {
        if !Rx.test("^screen-[0-9]{2}$", id) { throw StudioError("截图编号不合法：\(id)") }
    }

    func assertIdle(_ dir: String) throws {
        if isRunning(dir) { throw StudioError("项目正在运行，先停止再修改") }
    }

    /// 交付包里的文件在软件外被改过时：overwrite 为 true 用软件里的内容重新生成（手改的文件另存一份，不会被清理），
    /// 为 false 保留手改的交付包，这次不更新（以后再更新时还会再问）。
    @discardableResult
    public func resolveExternalEdits(_ dir: String, overwrite: Bool) async throws -> Task<RunResult, Never>? {
        try assertEditable(dir)
        try assertIdle(dir)
        if overwrite {
            try await updateState(dir) { state in
                state.overwriteExternalEdits = true
                var buildStep = state[step: .build] ?? StepState(.emptyObject)
                buildStep.status = .pending
                state[step: .build] = buildStep
            }
            return start(dir, RunOptions(from: PipelineStepName.build.rawValue, force: [PipelineStepName.build.rawValue]))
        }
        try await updateState(dir) { state in
            var buildStep = state[step: .build] ?? StepState(.emptyObject)
            buildStep.status = .done
            buildStep.clearInputHash()
            buildStep.clearMessage()
            state[step: .build] = buildStep
            let allDone = PIPELINE_STEPS.allSatisfy {
                let status = state[step: PipelineStepName(rawValue: $0)]?.status
                return status == .done || status == .skipped
            }
            state.status = allDone ? .done : .idle
            appendLog(&state, "保留了在软件外改过的交付包，这次没有更新")
        }
        return nil
    }

    public func confirmPlan(_ dir: String) async throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        try await updateState(dir) { state in
            var planStep = state[step: .plan] ?? StepState(.emptyObject)
            planStep.status = .done
            state[step: .plan] = planStep
            appendLog(&state, "规划已确认")
        }
        return start(dir, RunOptions(from: PipelineStepName.prompts.rawValue))
    }

    public func savePlanScreen(_ dir: String, _ id: String, _ patch: JSON) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        let paths = projectPaths(dir)
        guard var plan = try FS.readJSON(paths.screenPlan) else { throw StudioError("规划文件里找不到这一屏，可以直接编辑这一屏的提示词") }
        // 兼容历史格式：数组 / { screens } / { flow }，行里用 id 或 screenId
        let key: String? = plan.isArray ? nil : (plan["screens"].isTruthy ? "screens" : "flow")
        var rows = (key == nil ? plan : plan[key!] ?? .null).array ?? []
        let index = (Int(id.replacingOccurrences(of: "screen-", with: "")) ?? 0) - 1
        let found = rows.firstIndex { $0.isObject && ($0["id"]?.string == id || $0["screenId"]?.string == id) }
            ?? (index >= 0 && index < rows.count && rows[index].isObject ? index : nil)
        guard let position = found else { throw StudioError("规划文件里找不到这一屏，可以直接编辑这一屏的提示词") }
        for field in ["title", "pageType", "activeTab", "mustShow", "sampleData", "visualBrief", "textContract"] {
            if let value = patch[field] { rows[position][field] = value }
        }
        if let key { plan[key] = .array(rows) } else { plan = .array(rows) }
        try FS.writeJSONAtomic(paths.screenPlan, plan)
        try await markDirty(dir, [PipelineStepName.prompts.rawValue])
    }

    public func savePrompt(_ dir: String, _ id: String, _ prompt: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        try FS.writeAtomic(projectPaths(dir).promptFile(id), ensureBrandBan(prompt))
        try await updateState(dir) { state in
            var shot = state[screen: id] ?? ScreenState(.emptyObject)
            shot.promptEdited = true
            state[screen: id] = shot
        }
        try await markDirty(dir, [PipelineStepName.prompts.rawValue])
    }

    public func regenerateScreen(_ dir: String, _ id: String) throws -> Task<RunResult, Never> {
        try assertEditable(dir)
        try assertScreenId(id)
        return start(dir, RunOptions(from: PipelineStepName.images.rawValue, forceScreens: [id]))
    }

    /// 换回以前用过的截图（来自归档）。当前的图同样先归档，所以还能再换回来。
    public func restoreScreen(_ dir: String, _ id: String, _ file: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        guard screenHistory(dir, id).contains(where: { $0["file"]?.string == file }) else { throw StudioError("找不到这张旧截图") }
        let sha = try await replaceScreenImage(dir, id, with: file, log: "\(id) 换回了以前的截图")
        let name = Path.basename(file)
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["screens"]?[id] = .obj(["source": "restored", "restoredFrom": .string(name), "imageSha256": .string(sha), "generatedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "screen-restored", "screenId": .string(id), "file": .string(name)]))
        }
        try await markDirty(dir, [PipelineStepName.gate.rawValue, PipelineStepName.content.rawValue, PipelineStepName.receipt.rawValue, PipelineStepName.build.rawValue])
    }

    /// 用另一张图替换这一屏：当前的图先归档，换上后要重新验收，说明按新图重写（人工改过的除外）
    func replaceScreenImage(_ dir: String, _ id: String, with file: String, log message: String) async throws -> String {
        try assertEditable(dir)
        let paths = projectPaths(dir)
        let target = paths.screenFile(id)
        if FS.exists(target) {
            let archiveDir = Path.join(paths.archive, "screens-\(timestampSlug())")
            try FS.mkdirp(archiveDir)
            var archived = Path.join(archiveDir, "\(id).png")
            var index = 2
            while FS.exists(archived) {
                archived = Path.join(archiveDir, "\(id)-\(index).png")
                index += 1
            }
            try FS.copy(target, archived)
        }
        try FS.writeAtomic(target, FS.read(file))
        let sha = try sha256File(target)
        let at = isoNow()
        try await updateState(dir) { state in
            var current = state[screen: id] ?? ScreenState(.emptyObject)
            current.imageSha = sha
            current.gate = .null
            current.generatedAt = at
            current.fromAlternate = true
            current.contentStale = true
            current.setImagePromptHashOrNull(current.promptHash)
            current.requestedChange = nil
            state[screen: id] = current
            appendLog(&state, message)
        }
        return sha
    }

    public func useAlternate(_ dir: String, _ id: String, _ file: String) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        guard listAlternates(dir, id).contains(where: { $0["file"]?.string == file }) else { throw StudioError("备选图不存在") }
        let sha = try await replaceScreenImage(dir, id, with: file, log: "\(id) 已换成备选图")
        FS.remove(file)
        let parts = Path.basename(file, ".png").components(separatedBy: "-")
        let providerId = parts.count > 6 ? parts[6...].joined(separator: "-") : ""
        let alternateName = Path.basename(file)
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["screens"]?[id] = .obj(["source": "alternate", "providerId": providerId.isEmpty ? .null : .string(providerId), "alternateFile": .string(alternateName), "imageSha256": .string(sha), "generatedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "alternate-used", "screenId": .string(id), "providerId": providerId.isEmpty ? .null : .string(providerId), "alternateFile": .string(alternateName)]))
        }
        try await markDirty(dir, [PipelineStepName.gate.rawValue, PipelineStepName.content.rawValue, PipelineStepName.receipt.rawValue, PipelineStepName.build.rawValue])
    }

    public func manualGate(_ dir: String, _ id: String, _ passed: Bool) async throws {
        try assertEditable(dir)
        try assertScreenId(id)
        try assertIdle(dir)
        let state = try readTypedState(dir)
        let sha = try sha256File(projectPaths(dir).screenFile(id))
        try await updateRecord(dir) { record in
            let at = isoNow()
            record["gate"]?[id] = .obj(["status": .string(passed ? "manual-passed" : "failed"), "method": "manual", "imageSha256": .string(sha), "checkedAt": .string(at)])
            record.append("history", .obj(["at": .string(at), "event": "gate", "screenId": .string(id), "status": .string(passed ? "manual-passed" : "failed"), "method": "manual"]))
        }
        let tokensHash = gateKey(state)
        try await updateState(dir) { draft in
            var shot = draft[screen: id] ?? ScreenState(.emptyObject)
            let previous = shot.gate.or(.emptyObject)
            let checkedAt = isoNow()
            let gate: JSON = passed
                ? previous.merging(.obj(["status": "manual-passed", "method": .string(previous["method"]?.string == "vision" ? "vision+manual" : "manual"), "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(checkedAt), "reasons": []]))
                : previous.merging(.obj(["status": "failed", "method": "manual", "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(checkedAt), "reasons": ["人工判定有软件名或不合格"]]))
            shot.gate = gate
            if passed { shot.requestedChange = nil }
            draft[screen: id] = shot
            appendLog(&draft, "\(id) 人工\(passed ? "确认通过" : "判定不合格")")
            let gateStatus = draft[step: .gate]?.status
            if gateStatus == .review || gateStatus == .failed {
                var gateStep = draft[step: .gate] ?? StepState(.emptyObject)
                gateStep.status = .pending
                draft[step: .gate] = gateStep
            }
        }
    }

    /// screens：[{ id, title?, text? }]
    /// design：整章设计说明（[{title, text}]），nil 表示不改
    public func saveContent(_ dir: String, overview: String?, screens patches: [JSON], design: [JSON]? = nil) async throws {
        try assertEditable(dir)
        if isForegroundRunning(dir) { try assertIdle(dir) }
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        // 改之前的文字先记进历史；连续自动保存时同一处 3 分钟内只记一份
        var versions: [ContentVersion] = []
        let oldOverview = content["cover"]?["overview"].text ?? ""
        if let overview, overview != oldOverview { versions.append(ContentVersion(target: "overview", text: oldOverview, source: "修改前")) }
        for patch in patches {
            guard let id = patch["id"]?.string, let old = content["screens"].items.first(where: { $0["id"]?.string == id }) else { continue }
            if let text = patch["text"]?.string, text != old["text"].text { versions.append(ContentVersion(target: id, title: old["title"].text, text: old["text"].text, source: "修改前")) }
        }
        let oldSections = content["design"]?["sections"].items ?? []
        if let design {
            for (index, section) in design.enumerated() where index < oldSections.count && section["text"].text != oldSections[index]["text"].text {
                versions.append(ContentVersion(target: "design-\(index + 1)", title: oldSections[index]["title"].text, text: oldSections[index]["text"].text, source: "修改前"))
            }
        }
        recordContentHistory(dir, versions, coalesce: true)
        if let design {
            content["design"] = .obj(["sections": .array(design.map { .obj(["title": .string($0["title"].text.jsTrimmed), "text": .string($0["text"].text)]) })])
        }
        if let overview { content["cover"] = content["cover"].or(.emptyObject).merging(.obj(["overview": .string(overview)])) }
        var screens = content["screens"].items
        var editedIds: [String] = []
        for patch in patches {
            guard let id = patch["id"]?.string, let index = screens.firstIndex(where: { $0["id"]?.string == id }) else { continue }
            if let title = patch["title"]?.string {
                screens[index]["title"] = .string(title.jsTrimmed)
                screens[index]["caption"] = .string("图\(index + 1) \(title.jsTrimmed)")
            }
            if let text = patch["text"]?.string { screens[index]["text"] = .string(text) }
            editedIds.append(id)
        }
        content["screens"] = .array(screens)
        content["screenshotReview"] = nil
        try FS.writeJSONAtomic(paths.content, content)
        let edited = editedIds
        try await updateState(dir) { state in
            for id in edited {
                var shot = state[screen: id] ?? ScreenState(.emptyObject)
                shot.textEdited = true
                shot.contentStale = false
                state[screen: id] = shot
            }
            if !edited.isEmpty { state.warnings = .array(state.warnings.items.filter { !($0.string ?? "").hasPrefix("截图已更换") }) }
            if overview != nil { state.overviewEdited = true }
            if design != nil { state.designEdited = true }
        }
        try await markDirty(dir, [PipelineStepName.receipt.rawValue, PipelineStepName.build.rawValue])
    }
}
