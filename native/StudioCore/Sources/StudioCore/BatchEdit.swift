import Foundation

// MARK: - 批量修改
//
// 后处理只有一个入口：选项目（或粘贴名单），写要改什么（照抄退回意见也行），再选几项不用 AI 的处理。
// 写了要改什么的：先给每个项目加上这条修改意见并整理（每个项目一次大模型请求），整理结果给用户看过、确认后，
// 进批量队列按并发逐个改（mode = feedback）。不用 AI 的处理（换代码模板、重新导出 PDF）和强制重做沿用原来的做法。

extension StudioCore {
    /// 批量修改第一步：给一个项目加上这条修改意见并整理。返回 { dir, ok, feedbackId, plan } 或 { dir, ok: false, reason }。
    public func organizeBatchEdit(_ dir: String, text: String) async -> JSON {
        let name = Path.basename(dir)
        func skip(_ reason: String) -> JSON { .obj(["dir": .string(dir), "name": .string(name), "ok": false, "reason": .string(reason)]) }
        guard let state = try? projectStore.read(dir) else { return skip("项目不存在") }
        if isSubmitted(state) { return skip("已提交，只读") }
        if state["readOnly"].isTruthy { return skip("只有交付包的历史项目，不能改") }
        let busy = batch.list().items.contains { $0["projectDir"]?.string == dir && ["queued", "paused", "running"].contains($0["status"]?.string ?? "") }
        if pipeline.isRunning(dir) || busy { return skip("正在运行或排队") }
        if (try? readPlan(dir)) == nil { return skip("还没有界面规划") }
        do {
            let item = try await pipeline.addFeedback(dir, text)
            let plan = try await pipeline.analyzeFeedback(dir)
            return .obj(["dir": .string(dir), "name": .string(state["request"]?["softwareName"]?.jsString ?? name), "ok": true, "feedbackId": item["id"] ?? .null, "plan": plan])
        } catch {
            return skip(messageOf(error))
        }
    }

    /// 取消批量修改时，把刚加上的修改意见撤掉（整理结果也一起清掉）。
    public func discardBatchEdit(_ dir: String, feedbackId: String) async {
        try? await pipeline.removeFeedback(dir, feedbackId)
    }
}
