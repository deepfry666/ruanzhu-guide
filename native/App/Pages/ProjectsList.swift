import StudioCore
import SwiftUI

extension ProjectsView {
    // MARK: 表格

    var table: some View {
        let list = rows
        let indices = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.element.dir, $0.offset) })
        return Table(list, selection: Binding(get: { selection }, set: { tableSelectionChanged($0) }), sortOrder: sortOrder) {
            TableColumn("截图") { row in
                ProjectThumbnailView(thumbnail: row.thumbnail, height: Metrics.thumbnailList.height)
                    .frame(width: Metrics.thumbnailList.width, height: Metrics.thumbnailList.height)
                    .padding(.vertical, Spacing.xs)
            }.width(Metrics.thumbnailList.width + Spacing.sm)
            // 勾选框：不用按住 ⌘ 也能多选；勾过之后单击行也是加选 / 取消
            TableColumn("") { row in
                Toggle("", isOn: Binding(
                    get: { selection.contains(row.dir) },
                    set: { checked in
                        if checked { selection.insert(row.dir); checkMode = true } else { selection.remove(row.dir) }
                        if selection.isEmpty { checkMode = false }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("勾选多个项目")
            }
            .width(22)
            TableColumn("软件名", value: \.name) { row in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(row.name).textStyle(Typography.bodyStrong).lineLimit(1)
                    let tags = rowTags(row)
                    if !tags.isEmpty {
                        HStack(spacing: Spacing.xs) { ForEach(tags, id: \.0) { TagView(text: $0.0, tone: $0.1) } }
                    }
                }
                .padding(.vertical, Spacing.sm)
                .staggeredEntrance(index: indices[row.dir] ?? 0, mode: entranceMode(row))
            }
            .width(min: 200, ideal: 260)
            TableColumn("状态", value: \.statusSortKey) { row in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    statusTag(row)
                    ProgressCell(row: row)
                }.staggeredEntrance(index: indices[row.dir] ?? 0, mode: entranceMode(row))
            }
                .width(min: 90, ideal: 180)
            TableColumn("交付") { row in
                if let files = row.bundleFiles {
                    Text("\(files) 个文件")
                } else if row.hasBundle {
                    Text("有")
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 56, ideal: 70)
            TableColumn("最近动过", value: \.recency) { row in Text(row.recency > 0 ? formatTime(ms: row.recency * 1000) : "—").foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 76, ideal: 90)

        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            guard presentation != "grid", (model.section == .projects || model.section == nil), model.projectPath.isEmpty else { return }
            // 双击（或回车）只打开双击的那一行；多选时第一下单击带来的加选 / 取消要撤回
            if let clicked = lastClicked, ids.contains(clicked) || beforeClick?.contains(clicked) == true {
                if let before = beforeClick, before.count > 1 || checkMode { selection = before }
                model.openProject(clicked)
            } else if ids.count == 1, let dir = ids.first {
                model.openProject(dir)
            }
        }
        .onDeleteCommand { if presentation != "grid" && model.projectPath.isEmpty && (model.section == .projects || model.section == nil) { askRemove(selectedRows) } }
        .onExitCommand { if presentation != "grid" && model.projectPath.isEmpty && (model.section == .projects || model.section == nil) { clearSelection() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { selectionBar }
        }
        .overlay {
            if model.projectsLoaded && model.projects.isEmpty {
                EmptyHint(title: "还没有项目", systemImage: "square.grid.2x2", message: "点工具栏「新建」或按 ⌘N 创建；以前用 skill 做过的项目可以在「设置 → 导入项目」里接进来。")
            } else if model.projectsLoaded && rows.isEmpty {
                EmptyHint(title: "没有符合条件的项目", systemImage: "magnifyingglass")
            }
        }
    }

    func rowTags(_ row: ProjectRow) -> [(String, Tone)] {
        var tags: [(String, Tone)] = []
        if row.origin == "imported", let grade = row.grade, let info = GRADE_LABEL[grade] { tags.append(("历史 · \(info.label)", info.tone)) }
        if row.historyReadOnly { tags.append(("只读", .neutral)) }
        if row.feedbackPending > 0 { tags.append(("\(row.feedbackPending) 条修改意见待处理", .blue)) }
        if row.pdfFontProblem { tags.append(("PDF 字体不对", .orange)) }
        return tags
    }

    @ViewBuilder
    func statusTag(_ row: ProjectRow) -> some View {
        if row.status != "running", let queue = row.queue, let label = QUEUE_LABEL[queue["status"]?.string ?? ""] {
            TagView(text: "\(label)\(queue["position"]?.int.map { " #\($0)" } ?? "")")
        } else {
            let info = PROJECT_STATUS[row.status] ?? (row.status, .neutral)
            HStack(spacing: Spacing.xs) {
                if model.codeBatch?.current == row.dir {
                    // 正在更新代码材料：一个一个处理，正在做的这个
                    ProgressView().controlSize(.mini)
                    TagView(text: "正在更新代码", tone: .blue)
                } else if model.codeBatch?.pending.contains(row.dir) == true {
                    TagView(text: "等待更新代码", tone: .neutral)
                } else {
                    TagView(text: row.bundleUpdating ? "\(info.label) · 交付包更新中" : info.label, tone: info.tone)
                    if let reason = model.codeFailed[row.dir] {
                        TagView(text: reason.hasPrefix("跳过") ? "代码没更新" : "代码更新失败", tone: .red).help(reason)
                    } else if model.codeUpdated.contains(row.dir) {
                        TagView(text: "代码已更新", tone: .green).help("这次打开软件以来更新过代码材料")
                    }
                }
                if row.submitted { TagView(text: "已提交", tone: .purple).help("已提交：只读，批量操作会跳过") }
            }
        }
    }

}
