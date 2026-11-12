import StudioCore
import SwiftUI

extension ProjectsView {
    func remove(_ targets: [ProjectRow], deleteFolder: Bool) {
        Task {
            var done = 0
            for target in targets {
                if await model.perform(nil, { try await model.core?.removeFromList(target.dir, deleteFolder: deleteFolder) }) { done += 1 }
            }
            selection.subtract(targets.map(\.dir))
            await model.reloadProjects()
            if done > 0 { model.toast(.success, deleteFolder ? "已移除 \(done) 个项目，文件夹已移到废纸篓" : "已从列表移除 \(done) 个项目") }
        }
    }

    /// 人工看过 PDF 觉得可以接受：不再标「PDF 字体不对」。
    func ignoreFonts(_ targets: [ProjectRow]) {
        let dirs = targets.filter(\.pdfFontProblem).map(\.dir)
        Task {
            var done = 0
            for dir in dirs {
                if await model.perform(nil, { try await model.core?.pipeline.ignorePdfFontWarning(dir) }) { done += 1 }
            }
            await model.reloadProjects()
            if done > 0 { model.toast(.success, "已忽略 \(done) 个项目的字体提示") }
        }
    }

    @ViewBuilder
    func contextMenu(_ ids: Set<String>) -> some View {
        let targets = model.projects.filter { ids.contains($0.dir) }
        if targets.count == 1, let row = targets.first {
            Button("打开") { model.openProject(row.dir) }
            Button("在访达中显示") { model.reveal(row.dir) }
            Button("在访达中打开") { model.open(row.dir) }
            Divider()
        }
        actionItems(targets)
    }

    /// 右键菜单和底部操作栏「更多」共用同一份操作，内容一致
    @ViewBuilder
    func actionItems(_ targets: [ProjectRow], primary: Bool = true) -> some View {
        if primary {
            Button("开始处理") { start(targets) }
            Button("导出…") { exportDirs = ExportRequest(dirs: targets.map(\.dir)) }
        }
        Button("批量修改…") { batchEdit = BatchEditRequest(dirs: targets.map(\.dir)) }
            .disabled(applyingCodeTemplate || model.pdfJob != nil)
        Divider()
        if targets.contains(where: { !$0.submitted && !$0.historyReadOnly }) {
            Button("标记为已提交") { setSubmitted(targets, true) }
        }
        if targets.contains(where: \.submitted) {
            Button("取消已提交") { setSubmitted(targets, false) }
        }
        if targets.contains(where: \.pdfFontProblem) {
            Button("忽略字体提示") { ignoreFonts(targets) }
        }
        if targets.contains(where: { $0.queue != nil && $0.queue?["status"]?.string != "running" }) {
            Button("移出队列") {
                Task {
                    await model.core?.batchRemoveProjects(targets.map(\.dir))
                    model.toast(.success, "已移出队列")
                }
            }
        }
        if let batchId = targets.first?.batchId {
            let members = model.projects.filter { $0.batchId == batchId }
            Divider()
            Button("选中同一批（\(members.count) 个，\(targets[0].batchLabel)）") {
                model.listQuery = ""
                model.listOnly = Set(members.map(\.dir))
                selection = Set(members.map(\.dir))
                checkMode = true
            }
        }
        Divider()
        Button("从列表移除…") { askRemove(targets) }
            .disabled(targets.allSatisfy { $0.status == "running" })
    }

    /// 选中项目后出现在底部：带文字的批量操作，和右键菜单内容一致
    var selectionBar: some View {
        let targets = selectedRows
        let count = targets.count
        return HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("已选 \(count) 个").fontWeight(.semibold).monospacedDigit()
                if checkMode || count > 1 {
                    Text("单击行加选或取消，双击打开").textStyle(Typography.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("开始处理（\(count)）", systemImage: "play.fill") { start(targets) }
                .buttonStyle(.primary)
            Button("导出（\(count)）…", systemImage: "square.and.arrow.up") { exportDirs = ExportRequest(dirs: targets.map(\.dir)) }
                .buttonStyle(.secondary)
            Menu {
                actionItems(targets, primary: false)
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.secondary)
            .fixedSize()
            Divider().frame(height: 20)
            Button("全选当前列表（\(rows.count)）") {
                selection = Set(rows.map(\.dir))
                checkMode = true
            }
            .buttonStyle(.borderless)
            .disabled(selection == Set(rows.map(\.dir)))
            Button("取消选择", systemImage: "xmark.circle.fill") { clearSelection() }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .help("取消选择（Esc）")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 表格里的点选。已经在多选（勾选过，或选了不止一个）时，不按修饰键的单击是「加选 / 取消」这一行，
    /// 和勾选框一致，不会把已勾选的清掉；只选了一个或没选时，单击仍是只选这一行（和访达一样）。
    /// ⌘ 点选、⇧ 连选、键盘上下键保持系统行为。
    /// 系统表格在多选时单击已选中的行会报告「什么都没选」，所以点的是哪一行按鼠标位置自己算。
    func tableSelectionChanged(_ next: Set<String>) {
        let previous = selection
        let event = NSApp.currentEvent
        let plainClick = event.map { [.leftMouseDown, .leftMouseUp].contains($0.type) && $0.modifierFlags.intersection([.command, .shift]).isEmpty } ?? false
        if plainClick, checkMode || previous.count > 1, let event, let clicked = clickedRow(event) ?? (next.count == 1 ? next.first : nil) {
            // 同一次点击可能回调多次，只处理一次
            if handledClick == event.timestamp { return }
            handledClick = event.timestamp
            beforeClick = previous
            lastClicked = clicked
            selection = previous.contains(clicked) ? previous.subtracting([clicked]) : previous.union([clicked])
        } else {
            beforeClick = previous
            lastClicked = next.subtracting(previous).first ?? (next.count == 1 ? next.first : nil)
            selection = next
        }
        if selection.isEmpty { checkMode = false }
    }

    /// 鼠标点在表格的哪一行（按当前列表顺序）
    func clickedRow(_ event: NSEvent) -> String? {
        guard let content = event.window?.contentView, let hit = content.hitTest(event.locationInWindow) else { return nil }
        var view: NSView? = hit
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView else { return nil }
        let index = table.row(at: table.convert(event.locationInWindow, from: nil))
        let list = rows
        return list.indices.contains(index) ? list[index].dir : nil
    }

    func clearSelection() {
        selection = []
        checkMode = false
    }

    func askRemove(_ targets: [ProjectRow]) {
        let removable = targets.filter { $0.status != "running" }
        if removable.isEmpty {
            if !targets.isEmpty { model.toast(.info, "选中的项目都在运行，先停止再移除") }
            return
        }
        removeTargets = removable
    }

    /// 确认框里列出项目名，最多 8 个
    func nameList(_ targets: [ProjectRow]) -> String {
        let names = targets.prefix(8).map { "· \($0.name)" }
        return (names + (targets.count > 8 ? ["… 等 \(targets.count) 个"] : [])).joined(separator: "\n")
    }

}
