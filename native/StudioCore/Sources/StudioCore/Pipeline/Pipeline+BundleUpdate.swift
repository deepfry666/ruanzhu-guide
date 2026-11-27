import Foundation

/// 每个项目一个延时任务；正在构建时合并新改动，结束后补跑，不取消文件写入。
actor BundleUpdates {
    private var jobs: [String: Task<Void, Never>] = [:]
    private var active: Set<String> = []
    private var again: Set<String> = []

    func schedule(_ dir: String, pipeline: Pipeline, immediate: Bool = false) {
        if active.contains(dir) { again.insert(dir); return }
        jobs[dir]?.cancel()
        jobs[dir] = Task {
            do { if !immediate { try await Task.sleep(for: .seconds(3)) } }
            catch { return }
            await execute(dir, pipeline)
        }
    }

    /// 同时最多跑 2 个项目的本机构建（LibreOffice 转 PDF 很吃资源），其余排队
    private var building = 0
    private let maxConcurrent = 2

    private func execute(_ dir: String, _ pipeline: Pipeline) async {
        active.insert(dir)
        while building >= maxConcurrent { try? await Task.sleep(for: .milliseconds(300)) }
        building += 1
        defer { building -= 1 }
        repeat {
            again.remove(dir)
            if !(await pipeline.updateBundleLocally(dir)) { again.remove(dir); break }
        } while again.contains(dir)
        active.remove(dir)
        jobs[dir] = nil
        pipeline.emit(.obj(["type": "bundle-updated", "projectDir": .string(dir)]))
    }

    func flush(_ dir: String, pipeline: Pipeline) async {
        if !active.contains(dir) { schedule(dir, pipeline: pipeline, immediate: true) }
        while let job = jobs[dir] { await job.value }
    }

    func hasWork() -> Bool { !jobs.isEmpty }
}

extension Pipeline {
    private func stepDoneOrSkipped(_ state: ProjectState, _ step: String) -> Bool {
        let status = state[step: PipelineStepName(rawValue: step)]?.status
        return status == .done || status == .skipped
    }

    /// 唯一的自动运行资格判断：前六步全完成，且至少一个本机步骤未完成。
    public func onlyLocalStepsRemain(_ state: ProjectState) -> Bool {
        guard !isSubmitted(state), state.readOnly != true else { return false }
        let pending = PIPELINE_STEPS.filter { !stepDoneOrSkipped(state, $0) }
        return !pending.isEmpty && pending.allSatisfy { $0 == PipelineStepName.receipt.rawValue || $0 == PipelineStepName.build.rawValue }
    }

    public func onlyLocalStepsRemain(_ state: JSON) -> Bool { onlyLocalStepsRemain(ProjectState(state)) }

    public func bundleNeedsContinuation(_ state: ProjectState) -> Bool {
        state.readOnly != true && !isSubmitted(state) && !onlyLocalStepsRemain(state)
            && PIPELINE_STEPS.contains { !stepDoneOrSkipped(state, $0) }
    }

    public func bundleNeedsContinuation(_ state: JSON) -> Bool { bundleNeedsContinuation(ProjectState(state)) }

    func scheduleBundleUpdate(_ dir: String) async {
        guard let state = try? readTypedState(dir), onlyLocalStepsRemain(state), !isQueued(dir),
              (state.bundleUpdateError ?? "").isEmpty else { return }
        await bundleUpdates.schedule(dir, pipeline: self)
        emit(.obj(["type": "bundle-dirty", "projectDir": .string(dir)]))
    }

    func updateBundleLocally(_ dir: String) async -> Bool {
        guard let state = try? readTypedState(dir), onlyLocalStepsRemain(state), !isQueued(dir), !isRunning(dir) else { return true }
        // 标记先于 start，避免列表把后台动作算作项目运行。
        bundleActive.withLock { _ = $0.insert(dir) }
        emit(.obj(["type": "bundle-updating", "projectDir": .string(dir)]))
        var options = RunOptions(from: PipelineStepName.receipt.rawValue, until: PipelineStepName.build.rawValue)
        options.bundleOnly = true
        let result = await start(dir, options).value
        bundleActive.withLock { _ = $0.remove(dir) }
        if result.status == "failed" {
            let error = result.error ?? "交付包更新失败"
            try? await updateState(dir) { $0.bundleUpdateError = error }
            return false
        }
        return true
    }
}

extension StudioCore {
    public func hasBundleWork() async -> Bool { await pipeline.bundleUpdates.hasWork() }

    /// 所有交付出口共用此检查，等待最新一次本机更新，绝不运行 AI。
    public func ensureBundleCurrent(_ dir: String) async throws {
        if pipeline.isForegroundRunning(dir) { throw StudioError("项目正在运行，请稍后再试") }
        var state = try pipeline.readTypedState(dir)
        if pipeline.onlyLocalStepsRemain(state) {
            if pipeline.isQueued(dir) { throw StudioError("项目在批量队列中，请等队列完成") }
            await pipeline.bundleUpdates.flush(dir, pipeline: pipeline)
            state = try pipeline.readTypedState(dir)
        }
        if let error = state.bundleUpdateError, !error.isEmpty { throw StudioError(error) }
        if state.readOnly != true, PIPELINE_STEPS.contains(where: {
            let status = state[step: PipelineStepName(rawValue: $0)]?.status
            return status != .done && status != .skipped
        }) {
            throw StudioError("这个项目需要先继续，交付包尚未更新")
        }
    }

    public func retryBundleUpdate(_ dir: String) async {
        guard let state = try? pipeline.readTypedState(dir), !isSubmitted(state), state.readOnly != true else { return }
        if !pipeline.bundleNeedsContinuation(state) {
            try? await pipeline.markDirty(dir, [PipelineStepName.receipt.rawValue, PipelineStepName.build.rawValue])
        } else {
            try? await pipeline.updateState(dir) { $0.bundleUpdateError = nil }
            await pipeline.scheduleBundleUpdate(dir)
        }
    }
}
