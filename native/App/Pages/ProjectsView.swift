import StudioCore
import SwiftUI

let QUEUE_LABEL: [String: String] = ["queued": "排队中", "paused": "已暂停"]

/// 时间筛选：项目在那段时间里新建、完成、生成交付包或有改动，任意一样都算；用本机时区的自然日。
let TIME_FILTERS: [(value: String, label: String)] = [("all", "全部时间"), ("today", "今天"), ("yesterday", "昨天"), ("week", "最近 7 天")]

struct ProjectsView: View {
    @Environment(AppModel.self) var model
    // 排序：默认按最近动过，新的在上；点表头换排法，记住上次选的
    @AppStorage("projects.sortKey") var sortKey = "recent"
    @AppStorage("projects.sortAscending") var sortAscending = false
    @State var initialEntranceIDs = Set<String>()
    @State var entranceInitialized = false
    @State var initialEntranceGroup: ProjectGroup?
    @State var datePickerOpen = false
    @State var selection = Set<String>()
    @State var exportDirs: ExportRequest?
    @State var removeTargets: [ProjectRow]?
    @State var batchEdit: BatchEditRequest?
    @State var applyingCodeTemplate = false
    /// 用勾选框勾过：之后单击行也是「加选 / 取消」，不会把已勾选的清掉
    @State var checkMode = false
    /// 最近一次单击的行和单击前的选择：双击打开时恢复选择，只打开双击的那一行
    @State var lastClicked: String?
    @State var beforeClick: Set<String>?
    @State var handledClick: TimeInterval = 0
    @State var startPlan: StartPlan?

    /// 开始处理前的清单：哪些会开始，哪些跳过、为什么
    struct StartPlan: Identifiable {
        let id = UUID()
        let dirs: [String]
        let skipped: [String]
    }

    /// 批量修改：选中的项目（空表示先粘贴名单）
    struct BatchEditRequest: Identifiable {
        let id = UUID()
        let dirs: [String]
    }

    struct ExportRequest: Identifiable {
        let id = UUID()
        let dirs: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.md) {
                SetupHint()
                QueueBar()
                groupBar
                if let only = model.listOnly {
                    Banner(.info, "只显示名单里的 \(only.count) 个项目", message: "分组、时间、批次筛选暂不生效。") {
                        Button("显示全部") { model.listOnly = nil }.buttonStyle(.secondary)
                    }
                }
                if !query.isEmpty, model.listOnly == nil {
                    Banner(.info, "正在全部项目里搜索", message: "分组、时间、批次筛选暂不生效；清空搜索后恢复。")
                }
                if let batch = model.codeBatch {
                    CodeBatchBanner(batch: batch, name: { dir in model.projects.first { $0.dir == dir }?.name ?? Path.basename(dir) })
                } else if applyingCodeTemplate {
                    Banner(.info, "正在准备更新代码材料…")
                }
                if let job = model.pdfJob {
                    Banner(.info, "正在重新导出 PDF：\(job.index + 1)/\(job.total)（\(model.projects.first { $0.dir == job.current }?.name ?? "")）")
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, hasTopContent ? Spacing.md : 0)
            // 项目页覆盖列表时卸载表格，避免离开导航栈后 AppKit 仍回调已销毁的行。
            if model.projectPath.isEmpty {
                table
            }
        }
        .navigationTitle("项目")
        .onChange(of: model.projectsLoaded, initial: true) { _, loaded in
            if loaded, ProjectGroup(rawValue: model.listStatus) == nil { model.listStatus = activeGroup.rawValue }
        }
        .onChange(of: model.devSelection) { _, next in if let next { selection = next; checkMode = next.count > 1 } }
        // 搜索、筛选后看不见的项目不再算选中，批量操作只作用于列表里看得到的（和访达一样）
        .onChange(of: selection.isEmpty) { _, empty in if empty { checkMode = false } }
        .onChange(of: rows.map(\.dir), initial: true) { _, order in
            model.navigationOrder = order
            if !entranceInitialized, model.projectsLoaded {
                initialEntranceIDs = Set(order)
                initialEntranceGroup = activeGroup
                entranceInitialized = true
            }
        }
        .onChange(of: model.listStatus) { _, _ in
            if let initialEntranceGroup, initialEntranceGroup != activeGroup { initialEntranceIDs = [] }
        }
        .onChange(of: rows.map(\.dir)) { _, visible in
            let shown = Set(visible)
            if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
            if selection.isEmpty { checkMode = false }
        }
        .onChange(of: batches.map(\.id)) { _, ids in
            // 选中的那一批已经不存在（项目都移除了），退回全部，免得列表莫名其妙是空的
            if batchFilter != "all", !ids.contains(batchFilter) { model.listBatch = "all" }
        }
        .onChange(of: model.devTimeFilter) { _, next in
            guard let value = next?.components(separatedBy: "#").first else { return }
            if value == "picker" { datePickerOpen = true }
            else if value.hasPrefix("date:"), let date = ISO8601DateFormatter().date(from: value.dropFirst(5) + "T12:00:00Z") { model.listPickedDate = date; model.listTime = "date" }
            else { model.listTime = value }
        }
        .navigationSubtitle(subtitle)
        .searchable(text: Binding(get: { model.listQuery }, set: { model.listQuery = $0 }), placement: .toolbar, prompt: "在全部项目里搜索软件名")
        // 自己换了搜索或筛选，刚看过的项目就不再特意留着
        .onChange(of: "\(model.listQuery)|\(model.listStatus)|\(model.listTime)|\(model.listBatch)") { _, _ in model.stickyProject = nil }
        .onChange(of: model.devNameListText) { _, value in if value != nil { batchEdit = BatchEditRequest(dirs: []) } }
        .onChange(of: model.devCodeBatch) { _, value in
            guard let mode = value?.components(separatedBy: "#").first, !selection.isEmpty else { return }
            startCodeTemplateBatch(rows.map(\.dir).filter(selection.contains), mode: mode, templateId: nil)
        }
        .onChange(of: model.listSelectRequest) { _, dir in
            guard let dir else { return }
            selection = [dir]
            model.listSelectRequest = nil
        }
        .toolbar { toolbar }
        .toolbarRole(.editor)
        .sheet(item: $exportDirs) { request in
            ExportSheet(dirs: request.dirs) { clearSelection() }
        }
        .sheet(item: $batchEdit) { request in
            BatchEditSheet(initial: request.dirs) {
                batchEdit = nil
                clearSelection()
            } cancel: { batchEdit = nil }
        }
        .confirmationDialog(removeTargets.map { $0.count == 1 ? "移除「\($0[0].name)」？" : "移除 \($0.count) 个项目？" } ?? "", isPresented: Binding(get: { removeTargets != nil }, set: { if !$0 { removeTargets = nil } }), titleVisibility: .visible) {
            Button("只从列表移除") { remove(removeTargets ?? [], deleteFolder: false) }
            Button("移除并把文件夹移到废纸篓", role: .destructive) { remove(removeTargets ?? [], deleteFolder: true) }
        } message: {
            Text("\((removeTargets?.count ?? 0) > 1 ? "\(nameList(removeTargets ?? []))\n\n" : "")只从列表移除：项目文件夹留在原处，以后可以在「设置 → 导入项目」里重新导入。\n移到废纸篓：项目文件夹（截图、文档、交付包）一起移到废纸篓，清空废纸篓前都可以恢复。")
        }
        .confirmationDialog(startPlan.map { "开始处理 \($0.dirs.count) 个项目？" } ?? "", isPresented: Binding(get: { startPlan != nil }, set: { if !$0 { startPlan = nil } }), titleVisibility: .visible) {
            Button("开始处理 \(startPlan?.dirs.count ?? 0) 个") { if let plan = startPlan { enqueue(plan.dirs) } }
        } message: {
            Text("跳过 \(startPlan?.skipped.count ?? 0) 个：\n\(startPlan?.skipped.joined(separator: "\n") ?? "")")
        }
    }

    var hasTopContent: Bool { model.codeBatch != nil || model.listOnly != nil || (!query.isEmpty && filtersActive) || applyingCodeTemplate || model.pdfJob != nil || QueueBar.visible(model) || setupMissing }
    var setupMissing: Bool { SetupHint.missing(model).isEmpty == false }

    var subtitle: String {
        let running = model.projects.filter { $0.status == "running" }.count
        let filtered = true
        let total = filtered ? "显示 \(rows.count) / 共 \(model.projects.count) 个" : "共 \(model.projects.count) 个"
        return running > 0 ? "\(total) · \(running) 个运行中" : total
    }

}
