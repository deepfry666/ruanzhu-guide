import Foundation

final class StepTracker: @unchecked Sendable {
    let started = nowMs()
    private let lock = NSLock()
    private var steps: [String: Double] = [:]
    private var order: [String] = []

    func add(_ step: String, _ ms: Double) {
        lock.withLock {
            if steps[step] == nil { order.append(step) }
            steps[step, default: 0] += ms
        }
    }

    var isEmpty: Bool { lock.withLock { steps.isEmpty } }
    var samples: [String: Double] { lock.withLock { steps } }
    var json: JSON {
        lock.withLock {
            var object = JSONObject()
            for step in order { object[step] = .number(steps[step]!) }
            return .object(object)
        }
    }
}

extension Pipeline {
    func stepImpl(_ step: PipelineStepName, _ ctx: StepContext) async throws -> StepOutcome {
        switch step {
        case .plan: return try await stepPlan(ctx)
        case .prompts: return try await stepPrompts(ctx)
        case .images: return try await stepImages(ctx)
        case .gate: return try await stepGate(ctx)
        case .content: return try await stepContent(ctx)
        case .design: return try await stepDesign(ctx)
        case .receipt: return try await stepReceipt(ctx)
        case .build: return try await stepBuild(ctx)
        default: throw StudioError("未知步骤：\(step.rawValue)")
        }
    }

    /// 开始运行（已经在运行时返回同一个任务）。
    @discardableResult
    public func start(_ dir: String, _ options: RunOptions = RunOptions()) -> Task<RunResult, Never> {
        running.withLock { table in
            if let existing = table[dir], let task = existing.task {
                if options.bundleOnly || !existing.bundleOnly { return task }
                return Task { _ = await task.value; return await self.start(dir, options).value }
            }
            let handle = RunHandle(cancellable: true)
            handle.bundleOnly = options.bundleOnly
            let task = Task<RunResult, Never> {
                let result = await self.runInner(dir, options)
                self.running.withLock { if $0[dir] === handle { $0[dir] = nil } }
                return result
            }
            handle.task = task
            table[dir] = handle
            return task
        }
    }

    /// 跑流水线，等它结束。
    @discardableResult
    public func run(_ dir: String, _ options: RunOptions = RunOptions()) async -> RunResult {
        await start(dir, options).value
    }

    public func cancel(_ dir: String) {
        running.withLock { $0[dir] }?.cancel()
    }

    /// 包一层：管理实时进度，结束后记录这次运行用时。
    func runInner(_ dir: String, _ options: RunOptions) async -> RunResult {
        if isSubmitted(try? projectStore.readTyped(dir)) { return RunResult(status: "failed", error: "已提交的项目只读，没有运行；要修改请先取消已提交") }
        let startedAt = isoNow()
        let tracker = StepTracker()
        let initial: JSON = .obj([
            "startedAt": .string(startedAt), "started": .number(tracker.started), "step": .null, "stepStarted": .null, "plannedSteps": [], "doneSteps": [],
            "screens": .emptyObject, "detail": .null, "reason": JSON.orNull(options.reason),
        ])
        if !options.bundleOnly { progress.withLock { $0[dir] = initial } }
        if !options.bundleOnly { emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": initial])) }
        var result: RunResult
        do {
            result = try await runSteps(dir, options, tracker)
        } catch {
            result = RunResult(status: "failed", error: messageOf(error))
            emit(.obj(["type": "log", "projectDir": .string(dir), "level": "error", "message": .string(messageOf(error))]))
        }
        progress.withLock { $0[dir] = nil }
        emit(.obj(["type": "progress", "projectDir": .string(dir), "progress": .null]))
        if !options.bundleOnly, !tracker.isEmpty {
            let entry: JSON = .obj(["startedAt": .string(startedAt), "ms": .number(nowMs() - tracker.started), "steps": tracker.json, "status": .string(result.status), "reason": JSON.orNull(options.reason)])
            try? await recordRun(dir, entry, samples: tracker.samples)
        }
        return result
    }

    func recordRun(_ dir: String, _ entry: JSON, samples: [String: Double]) async throws {
        let finishedAt = isoNow()
        var run = entry
        run["finishedAt"] = .string(finishedAt)
        let runEntry = run
        let ms = run["ms"]?.number ?? 0
        let state = try await updateState(dir) { draft in
            var timing = draft.timing.or(.obj(["totalMs": 0, "runs": []]))
            let total = (timing["totalMs"]?.number ?? 0) + ms
            timing["totalMs"] = .number(total)
            timing["runs"] = .array(Array((timing["runs"].items + [runEntry]).suffix(30)))
            var firstDone = false
            if runEntry["status"]?.string == ProjectStatus.done.rawValue, !timing["completedAt"].isTruthy {
                timing["completedAt"] = .string(finishedAt)
                timing["completedMs"] = .number(total)
                firstDone = true
            }
            draft.timing = timing
            appendLog(&draft, "本次运行用时 \(formatDuration(ms))\(firstDone ? "，项目完成，累计用时 \(formatDuration(total))" : "")")
        }
        let timing = state.timing ?? .emptyObject
        let firstDone = run["status"]?.string == ProjectStatus.done.rawValue && timing["completedAt"]?.string == finishedAt
        addStepSamples(samples)
        // 生成记录只在本软件确实生成或修改过东西（记录文件已存在）时更新，不在只导入、没改动的历史项目里新建文件
        if readRecord(dir) != nil {
            try await updateRecord(dir) { record in
                record["timing"] = .obj(["totalMs": timing["totalMs"], "completedMs": timing["completedMs"] ?? .null, "completedAt": timing["completedAt"] ?? .null, "runs": timing["runs"]])
                record.append("history", .obj(["at": .string(finishedAt), "event": "run", "status": runEntry["status"], "ms": runEntry["ms"], "steps": runEntry["steps"], "reason": runEntry["reason"]]))
            }
        }
        emit(.obj(["type": "run-finished", "projectDir": .string(dir), "name": state.request?.softwareName.map(JSON.string) ?? .null, "status": run["status"] ?? .null, "ms": .number(ms), "totalMs": timing["totalMs"] ?? 0, "firstDone": .bool(firstDone)]))
    }

    func runSteps(_ dir: String, _ options: RunOptions, _ tracker: StepTracker) async throws -> RunResult {
        guard let initial = try projectStore.readTyped(dir) else { return RunResult(status: "failed", error: "项目状态不存在") }
        if initial.readOnly == true { return RunResult(status: "failed", error: "只读的历史项目（没有文案和截图源文件），不能运行") }
        if options.bundleOnly {
            guard onlyLocalStepsRemain(initial), !isQueued(dir) else { return RunResult(status: ProjectStatus.idle.rawValue) }
        }
        let revision = initial.bundleRevision
        let settings = try await settingsStore.get()
        let batchId = options.batchId ?? "\(Path.basename(dir)):\(timestampSlug())"
        let fromIndex = options.from.flatMap { PIPELINE_STEPS.firstIndex(of: $0) } ?? 0
        if initial.contentDateNeedsRefresh == true, PIPELINE_STEPS.prefix(fromIndex).contains(where: {
            let status = initial[step: PipelineStepName(rawValue: $0)]?.status
            return status != .done && status != .skipped
        }) {
            throw StudioError("内容日期已更改，请在概览点击「继续运行」，先更新全部截图和说明，再使用单屏重生或重写文字")
        }
        let untilIndex = options.until.flatMap { PIPELINE_STEPS.firstIndex(of: $0) } ?? PIPELINE_STEPS.count - 1
        let force = Set(options.force)
        if fromIndex <= untilIndex { setProgress(dir, .obj(["plannedSteps": JSON(Array(PIPELINE_STEPS[fromIndex...untilIndex]))])) }
        try await updateState(dir) { state in
            if !options.bundleOnly { state.status = .running }
            state.clearLastError()
        }
        var index = fromIndex
        while index <= untilIndex {
            defer { index += 1 }
            let step = PIPELINE_STEPS[index]
            let stepName = PipelineStepName(rawValue: step)
            if options.bundleOnly {
                guard stepName == .receipt || stepName == .build else { throw StudioError("自动更新仅允许本机步骤") }
                let current = try readTypedState(dir)
                if current.bundleRevision != revision || !onlyLocalStepsRemain(current) || isQueued(dir) { return RunResult(status: ProjectStatus.idle.rawValue) }
            }
            if Task.isCancelled {
                try await updateState(dir) { state in
                    state.status = .canceled
                    appendLog(&state, "已停止")
                }
                return RunResult(status: ProjectStatus.canceled.rawValue)
            }
            var state = try readTypedState(dir)
            let stepState = state[step: stepName]
            if stepState?.status == .review, !force.contains(step) {
                try await updateState(dir) { $0.status = .waiting }
                return RunResult(status: ProjectStatus.waiting.rawValue, step: step)
            }
            if let inputHash = stepInputHash(stepName, dir, state, settings), stepState?.status == .done, stepState?.inputHash == inputHash, !force.contains(step) {
                setProgress(dir, .obj(["doneSteps": .array(doneSteps(dir) + [.string(step)])]))
                continue
            }
            let stepStarted = nowMs()
            setProgress(dir, .obj(["step": .string(step), "stepStarted": .number(stepStarted), "detail": .null]))
            let startedAt = isoNow()
            try await updateState(dir) { draft in
                var entry = draft[step: stepName] ?? StepState(.emptyObject)
                entry.status = .running
                entry.startedAt = startedAt
                entry.clearError()
                draft[step: stepName] = entry
            }
            emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": .string(StepStatus.running.rawValue)]))
            do {
                state = try readTypedState(dir)
                let ctx = StepContext(
                    projectDir: dir, state: state, settings: settings, batchId: batchId,
                    reviewPlan: options.reviewPlan ?? settings.pipeline.reviewPlanSingle,
                    forceScreens: options.forceScreens, forceContent: options.forceContent,
                    contentInstructions: options.contentInstructions, designInstruction: options.designInstruction,
                    forceDesign: force.contains(PipelineStepName.design.rawValue), bundleOnly: options.bundleOnly
                )
                let outcome = try await stepImpl(stepName, ctx)
                tracker.add(step, nowMs() - stepStarted)
                setProgress(dir, .obj(["doneSteps": .array(doneSteps(dir) + [.string(step)]), "detail": .null]))
                let finalHash = stepInputHash(stepName, dir, try readTypedState(dir), settings)
                let finishedAt = isoNow()
                try await updateState(dir) { draft in
                    if options.bundleOnly, draft.bundleRevision != revision { return }
                    draft[step: stepName] = StepState.completed(status: outcome.status, inputHash: finalHash, finishedAt: finishedAt, message: outcome.message)
                    if let reason = outcome.screenCountReason, !reason.isEmpty { draft.screenCountReason = reason }
                }
                emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": .string(outcome.status.rawValue)]))
                if outcome.status == .review {
                    try await updateState(dir) { draft in
                        draft.status = .waiting
                        appendLog(&draft, outcome.message ?? "「\(STEP_LABELS[step] ?? step)」等待确认")
                    }
                    return RunResult(status: ProjectStatus.waiting.rawValue, step: step)
                }
            } catch {
                tracker.add(step, nowMs() - stepStarted)
                let canceled = Task.isCancelled
                let message = canceled && isCancellation(error) ? "已取消" : messageOf(error)
                let finishedAt = isoNow()
                let label = STEP_LABELS[step] ?? step
                try await updateState(dir) { draft in
                    var entry = draft[step: stepName] ?? StepState(.emptyObject)
                    entry.status = canceled ? .pending : .failed
                    entry.error = message
                    entry.finishedAt = finishedAt
                    draft[step: stepName] = entry
                    if !options.bundleOnly { draft.status = canceled ? .canceled : .needsAttention }
                    if canceled { draft.clearLastError() } else { draft.lastError = "\(label)：\(message)" }
                    appendLog(&draft, canceled ? "已停止" : "\(label)失败：\(message)", canceled ? "info" : "error")
                }
                emit(.obj(["type": "step", "projectDir": .string(dir), "step": .string(step), "status": .string(StepStatus.failed.rawValue), "error": .string(message)]))
                return RunResult(status: canceled ? ProjectStatus.canceled.rawValue : "failed", step: step, error: message)
            }
        }
        let final = try readTypedState(dir)
        let allDone = PIPELINE_STEPS.allSatisfy {
            let status = final[step: PipelineStepName(rawValue: $0)]?.status
            return status == .done || status == .skipped
        }
        try await updateState(dir) {
            if !options.bundleOnly || allDone { $0.status = allDone ? .done : .idle }
            if allDone { $0.contentDateNeedsRefresh = nil }
        }
        return RunResult(status: allDone ? ProjectStatus.done.rawValue : ProjectStatus.idle.rawValue)
    }

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

    // MARK: - 修改意见：先攒清单，再整理，确认后统一修改

    /// target：指定改哪里（screen-XX / all / overview / design），nil 表示让软件判断。
    @discardableResult
    public func addFeedback(_ dir: String, _ text: String, target: String? = nil) async throws -> JSON {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        var item = FeedbackItem(.emptyObject)
        item.id = randomHex(4)
        item.text = value
        item.at = isoNow()
        item.status = "pending"
        if let target, !target.isEmpty { item.target = target }
        let added = item
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []) + [added]
            draft.feedbackPlan = .null
        }
        return added.raw
    }

    public func editFeedback(_ dir: String, _ id: String, _ text: String) async throws {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).map { item in
                guard item.id == id, item.status == "pending" else { return item }
                var next = item
                next.text = value
                return next
            }
            draft.feedbackPlan = .null
        }
    }

    public func setFeedbackTarget(_ dir: String, _ id: String, _ target: String?) async throws {
        try assertEditable(dir)
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).map { item in
                guard item.id == id, item.status == "pending" else { return item }
                var next = item
                next.target = target.flatMap { $0.isEmpty ? nil : $0 }
                return next
            }
            draft.feedbackPlan = .null
        }
    }

    public func removeFeedback(_ dir: String, _ id: String) async throws {
        try assertEditable(dir)
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).filter { $0.id != id }
            draft.feedbackPlan = .null
        }
    }

    /// 把清单里所有未处理的意见一起交给大模型，整理成「改哪几张图、重写哪几段文字」。
    public func analyzeFeedback(_ dir: String) async throws -> JSON {
        try assertEditable(dir)
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        if state.readOnly == true { throw StudioError("只读的历史项目不能修改") }
        let items = (state.feedback ?? []).filter { $0.status == "pending" }
        if items.isEmpty { throw StudioError("清单里没有待处理的修改意见") }
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划，先运行一次再提修改意见") }
        let content = try FS.readJSON(projectPaths(dir).content)
        var contentById: [String: JSON] = [:]
        for (index, screen) in (content?["screens"].items ?? []).enumerated() { contentById[screen["id"].or(.string(screenId(index))).jsString] = screen }
        let screens: [FeedbackScreenInfo] = plan["screens"].items.enumerated().map { index, screen in
            let id = screen["id"]?.jsString ?? ""
            let gate = state[screen: id]?.gate
            let inventory = gate?["inventory"].text ?? ""
            return FeedbackScreenInfo(
                figure: "图\(index + 1)",
                id: id,
                title: (contentById[id]?["title"].truthyValue ?? screen["title"] ?? .null).jsString,
                picture: inventory.isEmpty ? screen["visualBrief"].text : inventory,
                visibleText: gate?["visibleText"].items.map(\.jsString) ?? [],
                text: contentById[id]?["text"].text ?? "",
                sampleData: screen["sampleData"].items.map(\.jsString)
            )
        }
        let screenIds = screens.map(\.id)
        let hasDesign = state.request?.wantDesign == true || !(content?["design"]?["sections"]?.array?.isEmpty ?? true)
        let inputs = items.map { FeedbackInput(text: $0.text ?? "", target: feedbackTargetValid($0.target, screenIds: screenIds, hasDesign: hasDesign)) }
        // 整理失败（模型出错、格式不对）也不报错退出：按用户指定的位置列出，其余的在确认窗口里选位置
        var raw: JSON = .obj(["summary": "", "actions": [], "questions": []])
        var notice: String?
        do {
            raw = try await callLlm("feedback", dir, ChatJsonRequest(
                system: FEEDBACK_SYSTEM_NATIVE,
                user: feedbackUserPromptNative(softwareName: softwareName(state), screens: screens, overview: content?["cover"]?["overview"].text ?? "", hasDesign: hasDesign, items: inputs, profile: AppProfile(state.appProfile), ledger: plan["ledger"].items.map(\.jsString)),
                schema: FEEDBACK_SCHEMA_NATIVE,
                temperature: 0.2,
                maxTokens: 4000
            ))
        } catch {
            notice = "自动整理没有成功（\(messageOf(error).jsSlice(0, 120))）。指定了位置的意见已直接列出，其余的请在下面选择要改哪里。"
        }
        let repaired = repairFeedbackResult(raw, items: inputs, screenIds: screenIds, hasDesign: hasDesign)
        let result: JSON = .obj(["summary": raw["summary"].or(""), "actions": .array(repaired.actions), "questions": .array(repaired.questions)])
        func toIds(_ indexes: JSON?) -> [String] {
            uniqued((indexes?.array ?? []).compactMap { value -> String? in
                guard let number = value.number, number >= 1, Int(number) <= items.count else { return nil }
                return items[Int(number) - 1].id
            })
        }
        func labelOf(_ target: String) -> String { target == "all" ? "全部" : feedbackTargetLabel(target, screens: screens) }
        // 整理结果再规范一遍：「全部截图」展开成每一屏；同一屏同一类型合并；有重新规划时其余截图/说明动作并进去
        var merged: [(key: String, value: JSON)] = []
        for action in result["actions"].items {
            let type = action["type"]?.jsString ?? ""
            let target = action["target"]?.jsString ?? ""
            let targets = type == "image" && target == "all" ? screenIds : [type == "overview" ? "overview" : type == "design" ? "design" : type == "replan" ? "all" : target]
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            for target in targets {
                let key = "\(type):\(target)"
                if let position = merged.firstIndex(where: { $0.key == key }) {
                    var previous = merged[position].value
                    previous["instruction"] = .string("\(previous["instruction"]?.jsString ?? "")；\(instruction)")
                    previous["items"] = JSON(uniqued(previous["items"].items.map(\.jsString) + toIds(action["items"])))
                    merged[position].value = previous
                } else {
                    merged.append((key, .obj(["key": .string(key), "type": .string(type), "target": .string(target), "targetLabel": .string(labelOf(target)), "instruction": .string(instruction), "items": JSON(toIds(action["items"]))])))
                }
            }
        }
        var actions = merged.map(\.value)
        if let replanIndex = actions.firstIndex(where: { $0["type"]?.string == "replan" }) {
            var replan = actions[replanIndex]
            let others = actions.enumerated().filter { $0.offset != replanIndex && ["data", "image", "text"].contains($0.element["type"]?.string ?? "") }
            replan["items"] = JSON(uniqued(replan["items"].items.map(\.jsString) + others.flatMap { $0.element["items"].items.map(\.jsString) }))
            if !others.isEmpty {
                replan["instruction"] = .string("\(replan["instruction"]?.jsString ?? "")；\(others.map { "\($0.element["targetLabel"]?.jsString ?? "")：\($0.element["instruction"]?.jsString ?? "")" }.joined(separator: "；"))")
            }
            let removed = Set(others.map(\.offset))
            actions[replanIndex] = replan
            actions = actions.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        let order = ["replan": 0, "data": 1, "image": 2, "text": 3, "overview": 4, "design": 5]
        actions = actions.enumerated().sorted { a, b in
            let ta = order[a.element["type"]?.string ?? ""] ?? 9
            let tb = order[b.element["type"]?.string ?? ""] ?? 9
            if ta != tb { return ta < tb }
            let xa = a.element["target"]?.jsString ?? ""
            let xb = b.element["target"]?.jsString ?? ""
            if xa != xb { return localeCompareEn(xa, xb) }
            return a.offset < b.offset
        }.map(\.element)
        let questions: [JSON] = result["questions"].items.map { .obj(["question": $0["question"] ?? "", "items": JSON(toIds($0["items"]))]) }.filter { !($0["question"]?.jsString ?? "").jsTrimmed.isEmpty }
        let feedbackPlan: JSON = .obj([
            "createdAt": .string(isoNow()),
            "notice": JSON.maybe(notice),
            "summary": result["summary"] ?? "",
            "itemIds": JSON(items.compactMap(\.id)),
            "actions": .array(actions),
            "questions": .array(questions),
        ])
        try await updateState(dir) { $0.feedbackPlan = feedbackPlan }
        return feedbackPlan
    }

    /// 按确认后的动作统一修改：先改好所有要重生截图的提示词，再一次运行
    /// （截图同时生成、一起验收、一起重写说明、只构建一次）。actions 是界面上勾选、改过措辞后的动作。
    public func applyFeedback(_ dir: String, actions chosen: [JSON]) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let entered: Bool = applying.withLock { set in set.insert(dir).inserted }
        if !entered { throw StudioError("正在处理上一次的修改") }
        defer { applying.withLock { _ = $0.remove(dir) } }
        let prepared = try await prepareFeedback(dir, actions: chosen)
        if let options = prepared.options { start(dir, options) }
        return prepared.result
    }

    /// 按修改意见准备好：改数据、改提示词、记下处理了哪些意见，返回这次要怎么运行（不用运行时为 nil）。
    /// 单个项目确认后马上运行；批量修改时交给批量队列按并发运行。
    func prepareFeedback(_ dir: String, actions chosen: [JSON], reviewPlan: Bool? = nil) async throws -> (options: RunOptions?, result: JSON) {
        try assertEditable(dir)
        let state = try readTypedState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let screenIds = plan["screens"].items.map { $0["id"]?.jsString ?? "" }
        // 「全部截图」展开成每一屏
        let expanded: [JSON] = chosen.flatMap { action -> [JSON] in
            guard action["type"]?.string == "image", action["target"]?.string == "all" else { return [action] }
            return screenIds.enumerated().map { index, id in action.merging(.obj(["target": .string(id), "targetLabel": .string("图\(index + 1)")])) }
        }
        // 同一屏同一类型的修改合并成一条（确认窗口里手动加的可能和整理结果重复），免得同时改写同一份提示词
        var actions: [JSON] = []
        for action in expanded {
            let type = action["type"]?.string ?? ""
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            guard ["data", "image", "text", "overview", "design", "replan"].contains(type), !instruction.isEmpty else { continue }
            let target = ["overview", "design"].contains(type) ? type : type == "data" ? "all" : action["target"]?.jsString ?? ""
            let items = action["items"]?.array ?? []
            if let index = actions.firstIndex(where: { $0["type"]?.string == type && ($0["target"]?.jsString ?? "") == target }) {
                let previous = actions[index]
                let joined = previous["instruction"]?.jsString == instruction ? instruction : "\(previous["instruction"]?.jsString ?? "")；\(instruction)"
                actions[index] = previous.merging(.obj(["instruction": .string(joined), "items": JSON(uniqued(previous["items"].items.map(\.jsString) + items.map(\.jsString)))]))
            } else {
                actions.append(action.merging(.obj(["target": .string(target), "instruction": .string(instruction), "items": .array(items)])))
            }
        }
        for action in actions where ["image", "text"].contains(action["type"]?.string ?? "") {
            let target = action["target"]?.jsString ?? ""
            if !screenIds.contains(target) { throw StudioError("找不到这一屏：\(target)") }
        }
        if actions.isEmpty { throw StudioError("没有勾选任何修改") }
        let replan = actions.first { $0["type"]?.string == "replan" }
        let dataAction = replan != nil ? nil : actions.first { $0["type"]?.string == "data" }
        let imageActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "image" }
        let textActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "text" }
        let overview = actions.first { $0["type"]?.string == "overview" }
        let design = actions.first { $0["type"]?.string == "design" }
        if design != nil, state.request?.wantDesign != true { throw StudioError("这个项目没有开启「设计说明」章节，先在概览里打开") }

        // 0. 改数据：先改底账和示例数据，数据变了的屏重新拼好提示词（后面改图的动作在新提示词上改）
        var dataChanged: [String] = []
        if let dataAction { dataChanged = try await applyDataEdit(dir, state, dataAction["instruction"]?.jsString ?? "") }

        // 1. 改写要重生的截图的提示词（几张同时改）
        let paths = projectPaths(dir)
        let name = softwareName(state)
        let tokens = forbiddenBrandTokens(name, extraTokens(state))
        let settings = try await settingsStore.get()
        let withoutNameLines: @Sendable (String) -> String = { text in
            text.components(separatedBy: "\n").filter { !$0.hasPrefix("Project context exact software name:") && !$0.contains(BRAND_BAN_BLOCK) }.joined(separator: "\n")
        }
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        let editedResults: [Result<(String, String), Error>] = await mapLimit(imageActions, 3) { action, _ in
            do {
                let target = action["target"]?.jsString ?? ""
                var current = FS.readTextIfExists(paths.promptFile(target))
                if current == nil || current!.isEmpty {
                    let screen = plan["screens"].items.first { $0["id"]?.string == target } ?? .emptyObject
                    current = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
                }
                let result = try await self.callLlm("feedback", dir, ChatJsonRequest(
                    system: PROMPT_EDIT_SYSTEM,
                    user: promptEditUserPrompt(prompt: current!, instruction: action["instruction"]?.jsString ?? ""),
                    schema: PROMPT_EDIT_SCHEMA,
                    check: { draft in
                        let hits = findBrandHits([withoutNameLines(draft["prompt"].text)], tokens)
                        return hits.isEmpty ? [] : ["新提示词里出现了软件名/品牌词：\(hits.joined(separator: "、"))，界面上不能出现，请去掉"]
                    },
                    temperature: 0.3,
                    maxTokens: 6000
                ))
                return .success((target, ensureBrandBan(result["prompt"]?.jsString ?? "")))
            } catch {
                return .failure(error)
            }
        }
        var edited: [(String, String)] = []
        for result in editedResults {
            switch result {
            case .success(let item): edited.append(item)
            case .failure(let error): throw error
            }
        }
        try FS.mkdirp(paths.prompts)
        for (id, prompt) in edited { try FS.writeAtomic(paths.promptFile(id), prompt) }

        // 2. 记下这次处理了哪些意见
        let appliedItemIds = uniqued(actions.flatMap { $0["items"].items.map(\.jsString) })
        let at = isoNow()
        let summary = actions.map { "\($0["targetLabel"].truthyValue?.jsString ?? $0["target"]?.jsString ?? "")：\($0["instruction"]?.jsString ?? "")" }.joined(separator: "；")
        let editedList = edited
        // 重生后验收时核对这条修改有没有体现在图上，没有就自动重生
        let requestedChanges: [(String, String)] = imageActions.map { ($0["target"]?.jsString ?? "", $0["instruction"]?.jsString ?? "") }
        let textTargets = textActions.map { $0["target"]?.jsString ?? "" }
        let replanInstruction = replan?["instruction"]?.jsString
        let hasOverview = overview != nil
        try await updateState(dir) { draft in
            let currentName = draft.request?.softwareName ?? ""
            for (id, prompt) in editedList {
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.promptEdited = true
                shot.promptHash = promptIdentity(prompt, currentName)
                draft[screen: id] = shot
            }
            for (id, change) in requestedChanges where !id.isEmpty && !change.isEmpty {
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.requestedChange = change
                draft[screen: id] = shot
            }
            for target in textTargets {
                guard var shot = draft[screen: target] else { continue }
                shot.textEdited = false
                draft[screen: target] = shot
            }
            if hasOverview { draft.overviewEdited = false }
            if let replanInstruction {
                var req = draft.request ?? ProjectRequest(.emptyObject)
                let notes = [req.notes ?? "", "修改意见：\(replanInstruction)"].filter { !$0.isEmpty }.joined(separator: "\n")
                req.notes = notes
                draft.request = req
            }
            let applied = Set(appliedItemIds)
            draft.feedback = (draft.feedback ?? []).map { item in
                guard let itemId = item.id, applied.contains(itemId), item.status == "pending" else { return item }
                var next = item
                next.status = "done"
                next.doneAt = at
                next.appliedAs = summary
                return next
            }
            draft.feedbackPlan = .null
            appendLog(&draft, "按修改意见统一修改：\(summary)")
        }
        let texts: [JSON] = (state.feedback ?? []).filter { appliedItemIds.contains($0.id ?? "") }.map { .obj(["id": $0.id.map(JSON.string), "text": $0.text.map(JSON.string)]) }
        let actionRecords: [JSON] = actions.map { .obj(["type": $0["type"], "target": $0["target"], "instruction": $0["instruction"]]) }
        try await updateRecord(dir) { record in
            let entry: JSON = .obj(["at": .string(at), "items": .array(texts), "actions": .array(actionRecords)])
            record["feedback"] = .array(Array((record["feedback"].items + [entry]).suffix(100)))
            record.append("history", JSON.obj(["event": "feedback"]).merging(entry))
        }

        // 3. 一次运行完成所有修改
        var contentInstructions: [String: String] = [:]
        for action in textActions { contentInstructions[action["target"]?.jsString ?? ""] = action["instruction"]?.jsString ?? "" }
        if let overview { contentInstructions["overview"] = overview["instruction"]?.jsString ?? "" }
        let onlyData = dataAction != nil && actions.allSatisfy { $0["type"]?.string == "data" }
        if onlyData && dataChanged.isEmpty {
            return (nil, .obj(["started": false, "data": 0, "appliedItems": .number(Double(appliedItemIds.count))]))
        }
        let from = replan != nil ? PipelineStepName.plan.rawValue : !imageActions.isEmpty || !dataChanged.isEmpty ? PipelineStepName.prompts.rawValue : !textActions.isEmpty || overview != nil ? PipelineStepName.content.rawValue : PipelineStepName.design.rawValue
        let options = RunOptions(
            from: from,
            force: (replan != nil ? [PipelineStepName.plan.rawValue] : []) + (design != nil ? [PipelineStepName.design.rawValue] : []),
            forceScreens: uniqued(imageActions.map { $0["target"]?.jsString ?? "" } + dataChanged),
            contentInstructions: contentInstructions,
            designInstruction: design?["instruction"]?.jsString,
            reviewPlan: reviewPlan,
            reason: "修改意见"
        )
        return (options, .obj(["started": true, "data": .number(Double(dataChanged.count)), "images": .number(Double(uniqued(imageActions.map { $0["target"]?.jsString ?? "" } + dataChanged).count)), "texts": .number(Double(textActions.count + (overview != nil ? 1 : 0))), "design": .bool(design != nil), "replan": .bool(replan != nil), "appliedItems": .number(Double(appliedItemIds.count))]))
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

extension Pipeline {
    /// 已提交的项目只读
    func assertEditable(_ dir: String) throws { try assertNotSubmitted(try projectStore.readTyped(dir)) }
}
