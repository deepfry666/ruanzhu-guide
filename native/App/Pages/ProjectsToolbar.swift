import StudioCore
import SwiftUI

extension ProjectsView {
    // 同一区域使用一个承载视图，减少离开列表时逐项重建原生工具栏的布局工作。
    @ViewBuilder
    var toolbar: some View {
        HStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                // 时间和批次合在一个菜单里，免得工具栏太挤
                Menu {
                    Picker("时间", selection: Binding(get: { model.listTime }, set: { model.listTime = $0 })) {
                        ForEach(TIME_FILTERS, id: \.value) { Text($0.label).tag($0.value) }
                        if timeFilter == "date" { Text(rangeLabel).tag("date") }
                    }
                    .pickerStyle(.inline)
                    Button("选择日期…") { datePickerOpen = true }
                    if !batches.isEmpty {
                        Picker("批量新建的批次", selection: Binding(get: { model.listBatch }, set: { model.listBatch = $0 })) {
                            Text("全部批次").tag("all")
                            ForEach(batches, id: \.id) { batch in Text("\(batch.label)（\(batch.count) 个）").tag(batch.id) }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Label(rangeLabel, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                }
                .help("按时间或批次筛选：选一批后点「全选」就能一起导出")
                .popover(isPresented: $datePickerOpen, arrowEdge: .bottom) {
                    VStack(alignment: .trailing, spacing: Spacing.md) {
                        DatePicker("", selection: Binding(get: { model.listPickedDate }, set: { model.listPickedDate = $0 }), in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                        HStack {
                            Button("取消") { datePickerOpen = false }
                            Button("筛选这一天") {
                                model.listTime = "date"
                                model.listBatch = "all"
                                datePickerOpen = false
                            }
                            .buttonStyle(.primary)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(Spacing.lg)
                }
                Picker("排序", selection: $sortKey) {
                    Text("最近动过").tag("recent")
                    Text("软件名").tag("name")
                    Text("状态").tag("status")
                    Text("最近构建").tag("build")
                }.pickerStyle(.menu)
                Button(sortAscending ? "升序" : "降序", systemImage: sortAscending ? "arrow.up" : "arrow.down") { sortAscending.toggle() }
                    .labelStyle(.titleAndIcon)
            }
            Picker("显示方式", selection: $presentation) {
                Text("列表").tag("list")
                Text("网格").tag("grid")
            }.pickerStyle(.segmented).fixedSize()
            Spacer(minLength: Spacing.md)
            HStack(spacing: Spacing.sm) {
                Button { model.showNewProject() } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(.primary)
                    .labelStyle(.titleAndIcon)
                    .disabled(model.trialMeasure)
                if selection.isEmpty {
                    Button { model.batchModification = BatchModificationRequest(dirs: [], finished: clearSelection) } label: { Label("批量修改", systemImage: "list.bullet.clipboard") }
                        .labelStyle(.titleAndIcon)
                        .help("批量修改：粘一份软件名清单（或先多选项目），写要改什么，一次改完")
                    Button {
                        let dirs = model.projects.filter { $0.hasBundle && $0.status != "missing" && ($0.status == "done" || $0.origin == "imported") }.map(\.dir)
                        if dirs.isEmpty { model.toast(.info, "还没有已完成的项目") } else { exportDirs = ExportRequest(dirs: dirs) }
                    } label: {
                        Label("导出全部已完成", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("导出全部已完成")
                    Button {
                        selection = Set(rows.map(\.dir))
                        checkMode = true
                    } label: { Label("全选", systemImage: "checkmark.circle") }
                        .labelStyle(.titleAndIcon)
                        .help("全选当前列表（⌘A）")
                        .disabled(rows.isEmpty)
                }
            }
        }
    }
}
