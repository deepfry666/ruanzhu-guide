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

    private func execute(_ dir: String, _ pipeline: Pipeline) async {
        active.insert(dir)
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
    /// 唯一的自动运行资格判断：前六步全完成，且至少一个本机步骤未完成。
    public func onlyLocalStepsRemain(_ state: JSON) -> Bool {
        guard !isSubmitted(state), !state["readOnly"].isTruthy else { return false }
        let pending = PIPELINE_STEPS.filter { !["done", "skipped"].contains(state["steps"]?[$0]?["status"].text ?? "") }
        return !pending.isEmpty && pending.allSatisfy { ["receipt", "build"].contains($0) }
    }

    public func bundleNeedsContinuation(_ state: JSON) -> Bool {
        !state["readOnly"].isTruthy && !isSubmitted(state) && !onlyLocalStepsRemain(state)
            && PIPELINE_STEPS.contains { !["done", "skipped"].contains(state["steps"]?[$0]?["status"].text ?? "") }
    }

    func scheduleBundleUpdate(_ dir: String) async {
        guard let state = try? readState(dir), onlyLocalStepsRemain(state), !isQueued(dir),
              !state["bundleUpdateError"].isTruthy else { return }
        await bundleUpdates.schedule(dir, pipeline: self)
        emit(.obj(["type": "bundle-dirty", "projectDir": .string(dir)]))
    }

    func updateBundleLocally(_ dir: String) async -> Bool {
        guard let state = try? readState(dir), onlyLocalStepsRemain(state), !isQueued(dir), !isRunning(dir) else { return true }
        // 标记先于 start，避免列表把后台动作算作项目运行。
        bundleActive.withLock { _ = $0.insert(dir) }
        emit(.obj(["type": "bundle-updating", "projectDir": .string(dir)]))
        var options = RunOptions(from: "receipt", until: "build")
        options.bundleOnly = true
        let result = await start(dir, options).value
        bundleActive.withLock { _ = $0.remove(dir) }
        if result.status == "failed" {
            let error = result.error ?? "交付包更新失败"
            try? await update(dir) { $0["bundleUpdateError"] = .string(error) }
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
        var state = try pipeline.readState(dir)
        if pipeline.onlyLocalStepsRemain(state) {
            if pipeline.isQueued(dir) { throw StudioError("项目在批量队列中，请等队列完成") }
            await pipeline.bundleUpdates.flush(dir, pipeline: pipeline)
            state = try pipeline.readState(dir)
        }
        if let error = state["bundleUpdateError"]?.string { throw StudioError(error) }
        if !state["readOnly"].isTruthy, PIPELINE_STEPS.contains(where: { !["done", "skipped"].contains(state["steps"]?[$0]?["status"].text ?? "") }) {
            throw StudioError("这个项目需要先继续，交付包尚未更新")
        }
    }

    public func retryBundleUpdate(_ dir: String) async {
        guard let state = try? pipeline.readState(dir), !isSubmitted(state), !state["readOnly"].isTruthy else { return }
        if !pipeline.bundleNeedsContinuation(state) {
            try? await pipeline.markDirty(dir, ["receipt", "build"])
        } else {
            try? await pipeline.update(dir) { $0["bundleUpdateError"] = nil }
            await pipeline.scheduleBundleUpdate(dir)
        }
    }
}
