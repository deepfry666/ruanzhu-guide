import StudioCore
import SwiftUI

extension ProjectsView {
    // MARK: 操作

    func start(_ targets: [ProjectRow]) {
        var dirs: [String] = []
        var skipped: [String] = []
        for row in targets {
            if row.submitted { skipped.append("· \(row.name)（已提交，只读）") }
            else if row.historyReadOnly { skipped.append("· \(row.name)（只读的旧项目）") }
            else if row.status == "running" { skipped.append("· \(row.name)（正在运行）") }
            else if row.queue?["status"]?.string == "queued" { skipped.append("· \(row.name)（已经在排队）") }
            else { dirs.append(row.dir) }
        }
        guard !dirs.isEmpty else {
            model.toast(.info, "选中的项目都在运行、排队、已提交或是只读的")
            return
        }
        // 全部能开始就直接开始；有要跳过的先说清楚
        if skipped.isEmpty { enqueue(dirs) } else { startPlan = StartPlan(dirs: dirs, skipped: Array(skipped.prefix(10)) + (skipped.count > 10 ? ["… 等 \(skipped.count) 个"] : [])) }
    }

    func enqueue(_ dirs: [String]) {
        startPlan = nil
        Task {
            await model.core?.batch.enqueue(dirs)
            model.toast(.success, "已开始：\(dirs.count) 个项目，同时处理 \(concurrencyText(model.settings.pipeline.batchConcurrency))")
            clearSelection()
        }
    }

    func setSubmitted(_ targets: [ProjectRow], _ value: Bool) {
        let dirs = targets.filter { value ? !$0.submitted && !$0.historyReadOnly : $0.submitted }.map(\.dir)
        guard let core = model.core, !dirs.isEmpty else { return }
        Task {
            do {
                let result = try await core.setSubmitted(dirs, value)
                await model.reloadProjects()
                if result.skipped.isEmpty { model.toast(.success, value ? "已标记 \(result.changed.count) 个为已提交，现在只读" : "已取消 \(result.changed.count) 个的已提交") }
                else { model.alert = AlertItem(title: "标记了 \(result.changed.count) 个，跳过 \(result.skipped.count) 个", message: result.skipped.joined(separator: "\n")) }
            } catch { model.toast(.error, messageOf(error)) }
        }
    }

    func startCodeTemplateBatch(_ dirs: [String], mode: String, templateId: String?) {
        guard let core = model.core, !applyingCodeTemplate else { return }
        applyingCodeTemplate = true
        Task {
            let result = await core.applyCodeTemplates(dirs, mode: mode, templateId: templateId)
            await model.reloadProjects()
            applyingCodeTemplate = false
            let done = result["done"].items
            let failed = result["failed"].items.map(\.jsString)
            let skipped = result["skipped"].items.map(\.jsString)
            let fontWarnings = done.flatMap { $0["warnings"].items.map(\.jsString) }
            let reassigned = done.filter { $0["reassigned"]?.string != nil }
            let reassignNote = reassigned.isEmpty ? "" : "；其中 \(reassigned.count) 个原来没有 Word 模板，已平均分到模板库里的模板"
            selection.subtract(done.compactMap { $0["dir"]?.string })
            let details = skipped.map { "跳过：\($0)" } + failed.map { "失败：\($0)" } + fontWarnings
            if !details.isEmpty {
                model.alert = AlertItem(title: "更新代码材料：成功 \(done.count) 个，跳过 \(skipped.count) 个，失败 \(failed.count) 项", message: (reassignNote.isEmpty ? "" : String(reassignNote.dropFirst()) + "。\n") + details.joined(separator: "\n"))
            } else {
                model.toast(.success, "已更新 \(done.count) 个项目：代码 PDF 都是 60 页，沿用所选模板的每页行数；TXT 换成 9 行开头，旧材料已归档\(reassignNote)")
            }
        }
    }
}
