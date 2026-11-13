import Foundation

// MARK: - 批量修改
//
// 共用整理入口：可添加一条意见，也可直接整理已经保存的清单。
// 整理结果仅供预览；确认后的动作由批量队列执行。

extension StudioCore {
    /// 批量修改整理：传入文字时先添加意见；省略文字时整理已保存的意见。返回 { dir, ok, feedbackId, plan } 或 { dir, ok: false, reason }。
    public func organizeBatchEdit(_ dir: String, text: String? = nil) async -> JSON {
        let name = Path.basename(dir)
        func skip(_ reason: String) -> JSON { .obj(["dir": .string(dir), "name": .string(name), "ok": false, "reason": .string(reason)]) }
        guard let state = try? projectStore.read(dir) else { return skip("项目不存在") }
        if isSubmitted(state) { return skip("已提交，只读") }
        if state["readOnly"].isTruthy { return skip("只有交付包的历史项目，不能改") }
        let busy = batch.list().items.contains { $0["projectDir"]?.string == dir && ["queued", "paused", "running"].contains($0["status"]?.string ?? "") }
        if pipeline.isRunning(dir) || busy { return skip("正在运行或排队") }
        if (try? readPlan(dir)) == nil { return skip("还没有界面规划") }
        do {
            let item: JSON?
            if let text { item = try await pipeline.addFeedback(dir, text) }
            else { item = nil }
            let plan = try await pipeline.analyzeFeedback(dir)
            return .obj(["dir": .string(dir), "name": .string(state["request"]?["softwareName"]?.jsString ?? name), "ok": true, "feedbackId": item?["id"] ?? .null, "plan": plan])
        } catch {
            return skip(messageOf(error))
        }
    }

    /// 取消批量修改时，把刚加上的修改意见撤掉（整理结果也一起清掉）。
    public func discardBatchEdit(_ dir: String, feedbackId: String) async {
        try? await pipeline.removeFeedback(dir, feedbackId)
    }
}
