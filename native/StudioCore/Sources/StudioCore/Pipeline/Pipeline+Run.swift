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
}

extension Pipeline {
    /// 已提交的项目只读
    func assertEditable(_ dir: String) throws { try assertNotSubmitted(try projectStore.readTyped(dir)) }
}
