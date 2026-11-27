import Foundation

let KEEP_FINISHED_DAYS: Double = 3

/// 生图任务账本（思路来自四季画布的 run ledger）：
/// - 异步任务号拿到就落盘，重启后续查，不重复提交；
/// - 启动时还停在「提交中」的尝试标为「提交结果未知（可能已扣费）」，交给用户决定。
public final class Ledger: @unchecked Sendable {
    let file: String
    let now: @Sendable () -> Double
    private let data = Locked<JSONObject>(JSONObject())
    private let serial = SerialQueue()

    public init(dataDir: String, now: @escaping @Sendable () -> Double = nowMs) {
        file = Path.join(dataDir, "image-jobs.json")
        self.now = now
    }

    private func iso() -> String { isoString(Date(timeIntervalSince1970: now() / 1000)) }

    private func persist() async {
        let snapshot = JSON.obj(["jobs": .object(data.current)])
        let file = self.file
        _ = try? await serial.run { try FS.writeJSONAtomic(file, snapshot) }
    }

    public func initialize() async {
        let stored = FS.readJSONQuiet(file)?["jobs"]?.object ?? JSONObject()
        let cutoff = now() - KEEP_FINISHED_DAYS * 86_400_000
        var changed = false
        var jobs = JSONObject()
        for (jobId, rawJob) in stored {
            var job = ImageJob(rawJob)
            if job.state != "running", (parseISO(job.updatedAt) ?? 0) < cutoff {
                changed = true
                continue
            }
            var attempts = job.attempts ?? []
            for index in attempts.indices where attempts[index].state == "submitting" {
                attempts[index].state = "unknown"
                attempts[index].error = "软件在提交途中退出，不确定中转站是否已收到请求（可能已扣费）"
                changed = true
            }
            job.attempts = attempts
            if job.state == "running", !attempts.contains(where: { $0.state == "waiting" }) {
                job.state = attempts.contains(where: { $0.state == "unknown" }) ? "needs-attention" : "interrupted"
                changed = true
            }
            jobs[jobId] = job.raw
        }
        data.withLock { $0 = jobs }
        if changed { await persist() }
    }

    public func getTyped(_ jobId: String) -> ImageJob? { data.withLock { $0[jobId].map(ImageJob.init) } }

    public func get(_ jobId: String) -> JSON? { getTyped(jobId)?.raw }

    public func list(_ filter: (JSON) -> Bool = { _ in true }) -> [JSON] { data.current.values.filter(filter) }

    public func createJob(_ job: ImageJob) async {
        var entry = job
        entry.state = "running"
        entry.attempts = []
        entry.createdAt = iso()
        entry.updatedAt = iso()
        let jobId = entry.jobId ?? ""
        data.withLock { $0[jobId] = entry.raw }
        await persist()
    }

    public func createJob(_ job: JSON) async {
        await createJob(ImageJob(job))
    }

    private func mutateAttempt(_ jobId: String, _ attemptId: String, _ body: (inout ImageAttempt) -> Void) -> Bool {
        data.withLock { jobs in
            guard let raw = jobs[jobId] else { return false }
            var job = ImageJob(raw)
            guard var attempts = job.attempts,
                  let index = attempts.firstIndex(where: { $0.attemptId == attemptId }) else { return false }
            body(&attempts[index])
            job.attempts = attempts
            job.updatedAt = iso()
            jobs[jobId] = job.raw
            return true
        }
    }

    public func startAttempt(_ jobId: String, _ attempt: ImageAttempt) async {
        var entry = attempt
        entry.state = "submitting"
        entry.startedAt = iso()
        data.withLock { jobs in
            guard let raw = jobs[jobId] else { return }
            var job = ImageJob(raw)
            job.attempts = (job.attempts ?? []) + [entry]
            job.updatedAt = iso()
            jobs[jobId] = job.raw
        }
        await persist()
    }

    public func startAttempt(_ jobId: String, _ attempt: JSON) async {
        await startAttempt(jobId, ImageAttempt(attempt))
    }

    public func markTaskId(_ jobId: String, _ attemptId: String, _ taskId: String) async {
        let found = mutateAttempt(jobId, attemptId) { attempt in
            attempt.taskId = taskId
            attempt.state = "waiting"
        }
        if found { await persist() }
    }

    public func finishAttempt(_ jobId: String, _ attemptId: String, _ result: ImageAttempt) async {
        let endedAt = iso()
        let found = mutateAttempt(jobId, attemptId) { attempt in
            var merged = ImageAttempt(attempt.raw.merging(result.raw))
            merged.endedAt = endedAt
            attempt = merged
        }
        if found { await persist() }
    }

    public func finishAttempt(_ jobId: String, _ attemptId: String, _ result: JSON) async {
        await finishAttempt(jobId, attemptId, ImageAttempt(result))
    }

    public func finishJob(_ jobId: String, _ result: ImageJob) async {
        let found: Bool = data.withLock { jobs in
            guard let raw = jobs[jobId] else { return false }
            var next = ImageJob(raw.merging(result.raw))
            next.updatedAt = iso()
            jobs[jobId] = next.raw
            return true
        }
        if found { await persist() }
    }

    public func finishJob(_ jobId: String, _ result: JSON) async {
        await finishJob(jobId, ImageJob(result))
    }

    /// 重启后需要续查的远端任务。
    public func remoteWaitingTyped() -> [(job: ImageJob, attempt: ImageAttempt)] {
        var result: [(ImageJob, ImageAttempt)] = []
        for raw in data.current.values {
            let job = ImageJob(raw)
            for attempt in job.attempts ?? [] where attempt.state == "waiting" && !(attempt.taskId ?? "").isEmpty {
                result.append((job, attempt))
            }
        }
        return result
    }

    public func remoteWaiting() -> [(job: JSON, attempt: JSON)] {
        remoteWaitingTyped().map { ($0.job.raw, $0.attempt.raw) }
    }

    public func dismiss(_ jobId: String) async {
        let found: Bool = data.withLock { jobs in
            guard let raw = jobs[jobId] else { return false }
            var job = ImageJob(raw)
            job.state = "dismissed"
            job.updatedAt = iso()
            jobs[jobId] = job.raw
            return true
        }
        if found { await persist() }
    }
}
