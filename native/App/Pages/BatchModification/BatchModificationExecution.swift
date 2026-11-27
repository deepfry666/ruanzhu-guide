import StudioCore
import SwiftUI

extension BatchModificationState {
    /// 在最后确认处再次读状态；只有保存了用户实际选中的动作，才能交给队列读取。
    func execute() async -> Bool {
        guard !busy, hasWork, let core = model.core else { return false }
        busy = true
        progress = "正在核对并提交…"
        defer { busy = false; progress = "" }
        let expected = Set(editable.map(\.dir))
        await refresh()
        guard expected == Set(editable.map(\.dir)) else {
            model.toast(.error, "项目状态已变化，请返回检查项目范围后再执行。")
            step = .write
            return false
        }
        let selected = chosen
        var prepared: [(dir: String, original: JSON, confirmed: JSON)] = []
        do {
            for preview in selected where force == "none" {
                guard let current = projects[preview.dir],
                      current.projectState.feedback == preview.data.projectState.feedback,
                      current.projectState.feedbackPlan == preview.originalPlan else {
                    throw StudioError("意见或整理结果已变化，请返回重新预览后执行。")
                }
                guard preview.chosen.allSatisfy({ !$0["instruction"].text.jsTrimmed.isEmpty }) else {
                    throw StudioError("已选择的修改指令不能为空，请返回预览补充或取消勾选。")
                }
            }
            if !codeDirs.isEmpty {
                let result = await core.applyCodeTemplates(codeDirs, mode: codeMode, templateId: codeMode == "fixed" ? templateId : nil)
                for done in result["done"].items { if let dir = done["dir"]?.string { completedCode[dir] = codeKey(dir) } }
                let problems = result["failed"].items + result["skipped"].items
                if !problems.isEmpty { throw StudioError("部分代码材料未完成，尚未提交模型任务：\n" + problems.map(\.jsString).joined(separator: "\n")) }
                // 每个已完成项目单独记账，部分失败重试不重复处理。
            }
            switch force {
            case "rewrite":
                _ = await core.batch.enqueue(editable.map(\.dir), name: "批量修改：只重写文字", mode: "rewrite")
            case "regenerate":
                for data in editable { try await core.regenerateProject(data.dir) }
            default:
                var ready: [String] = []
                for preview in selected {
                    var plan = preview.originalPlan
                    // 同一意见还有未选动作或未定位问题时，不能提前把整条意见标为完成。
                    let unfinished = preview.actions.enumerated().filter { !preview.checked[$0.offset] }.map(\.element) + preview.questions
                    let pendingIDs = Set(unfinished.flatMap { $0["items"].items.compactMap(\.string) })
                    let actions = preview.chosen.map { action in
                        var next = action
                        next["items"] = .array(action["items"].items.filter { !pendingIDs.contains($0.jsString) })
                        return next
                    }
                    plan["actions"] = .array(actions)
                    plan["questions"] = .array(preview.questions)
                    let confirmedPlan = plan
                    let originalPlan = preview.originalPlan
                    let originalFeedback = preview.data.projectState.feedback
                    try await core.projectStore.update(preview.dir) { raw in
                        var current = ProjectState(raw)
                        guard current.feedbackPlan == originalPlan,
                              current.feedback == originalFeedback else {
                            throw StudioError("意见已变化，未提交该项目，请重新整理。")
                        }
                        current.feedbackPlan = confirmedPlan
                        raw = current.raw
                    }
                    prepared.append((preview.dir, originalPlan, confirmedPlan))
                    ready.append(preview.dir)
                }
                if !ready.isEmpty { _ = await core.batch.enqueue(ready, name: "批量修改", mode: "feedback") }
                prepared = []
            }
            for dir in dirs { model.bump(dir) }
            await model.reloadProjects()
            model.toast(.success, "批量修改已提交")
            return true
        } catch {
            var rollbackFailed = false
            for saved in prepared.reversed() {
                do {
                    try await core.projectStore.update(saved.dir) { raw in
                        var current = ProjectState(raw)
                        // 不覆盖其他操作已写入的新计划。
                        if current.feedbackPlan == saved.confirmed { current.feedbackPlan = saved.original; raw = current.raw }
                    }
                } catch { rollbackFailed = true }
            }
            errorMessage = messageOf(error) + "\n已完成的本机处理或已入队任务会保留，请核对后再继续。" + (rollbackFailed ? "\n部分计划未能恢复，请返回重新整理。" : "")
            await refresh()
            await model.reloadProjects()
            return false
        }
    }
}
