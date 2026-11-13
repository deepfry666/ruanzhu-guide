import StudioCore
import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, plan, editor, delivery
    var id: String { rawValue }

    /// 旧的「截图」「文案」两页合并成了「编辑」
    init?(name: String) {
        if ["screens", "content"].contains(name) { self = .editor } else if let tab = ProjectTab(rawValue: name) { self = tab } else { return nil }
    }
}

struct ProjectDetailView: View {
    let dir: String
    @Binding var feedbackOpen: Bool
    let onInspectorData: (ProjectData) -> Void
    @Environment(AppModel.self) private var model
    @State private var data: ProjectData?
    @State private var contentReady = false
    @State private var loadError: String?
    @State private var tab: ProjectTab?
    @State private var renameOpen = false
    @State private var removeConfirm = false
    @State private var regenerateConfirm = false
    @State private var bloomTrigger = false
    @State private var sawGeneration = false
    @AppStorage("completedProjectBlooms") private var completedBlooms = ""

    var live: JSON? { model.signal(dir).live }
    var running: Bool { (data?.runningFlag ?? false) || data?.status == "running" || live != nil }

    var body: some View {
        Group {
            if let data {
                content(data)
            } else if let loadError {
                VStack {
                    backToProjects
                    ContentUnavailableView("项目打不开", systemImage: "exclamationmark.triangle", description: Text(loadError))
                }
            } else {
                VStack {
                    backToProjects
                    Text("正在打开项目…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: model.signal(dir).revision) { await reload() }
        // 回到列表时这个项目照样显示（即使状态变了不符合筛选）。
        .onAppear { model.stickyProject = dir }
        .onChange(of: model.devProjectTab) { _, next in if let next { tab = next } }
        .onChange(of: feedbackOpen) { _, open in
            if open, let data { onInspectorData(data) }
        }
        .onChange(of: model.devFeedbackOpen) { _, next in if let next { feedbackOpen = next } }
    }

    private var backToProjects: some View {
        Button("返回项目列表") { model.projectPath = [] }
            .keyboardShortcut("[", modifiers: .command)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
    }

    func reload() async {
        guard let core = model.core else { return }
        do {
            let next = ProjectData(json: try await core.getProject(dir))
            // 首次进入时让导航先完成布局；后续刷新直接更新，不延后保存反馈。
            if data == nil {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            let identity = Data(dir.utf8).base64EncodedString()
            let completed = Set(completedBlooms.split(separator: "|").map(String.init))
            if sawGeneration, next.status == "done", !next.state["bundleUpdating"].isTruthy, !completed.contains(identity) {
                completedBlooms += "|" + identity
                bloomTrigger.toggle()
                sawGeneration = false
            }
            if next.runningFlag, !next.state["bundleUpdating"].isTruthy { sawGeneration = true }

            data = next
            if feedbackOpen { onInspectorData(next) }
            loadError = nil
        } catch {
            loadError = messageOf(error)
        }
    }

    /// 每个项目首次打开时由状态决定，手动切换只影响当前项目。
    var activeTab: ProjectTab {
        tab ?? (data?.status == "done" ? .editor : .overview)
    }

    /// 历史项目列表当前顺序里的上一个 / 下一个（跟着列表的搜索和筛选）
    func neighbor(_ step: Int) -> String? {
        let order = model.navigationOrder
        guard let index = order.firstIndex(of: dir) else { return nil }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }

    func setSubmitted(_ value: Bool) {
        Task {
            await model.perform(value ? "已标记为已提交，项目现在只读" : "已取消已提交，可以修改了") { _ = try await model.core?.setSubmitted([dir], value) }
            await reload()
            await model.reloadProjects()
        }
    }

    func go(_ step: Int) {
        guard let target = neighbor(step) else { return }
        model.lastProjectTab = activeTab
        model.projectPath = [target]
    }

    @ViewBuilder
    func content(_ data: ProjectData) -> some View {
        let readOnly = data.readOnly
        let statusKey = running ? "running" : data.submitted ? "submitted" : readOnly ? "readonly" : data.status
        let status = PROJECT_STATUS[statusKey] ?? (data.status, .neutral)
        let waitingStep = STEP_ORDER.first { data.stepStatus($0) == "review" }
        let refresh: () -> Void = { Task { await reload() } }
        VStack(spacing: 0) {
            ProjectHeaderLayout {
                HStack(spacing: Spacing.sm) {
                    Button { model.projectPath = [] } label: {
                        Label("返回项目", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("返回项目列表（⌘[）")
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(data.name).textStyle(Typography.title).lineLimit(1).help(data.name)
                        TagView(text: status.label, tone: status.tone).bloom(trigger: bloomTrigger)
                    }
                }
                .frame(width: Metrics.sidebarWidth, alignment: .leading)
                Group {
                    SegmentedTabs(selection: Binding(get: { activeTab }, set: { tab = $0 }), items: [
                        .init(value: .overview, title: "概览"),
                        .init(value: .plan, title: "规划"),
                        .init(value: .editor, title: "编辑", count: data.screens.count),
                        .init(value: .delivery, title: "交付"),
                    ])
                }
                FlowLayout(spacing: Spacing.sm) {
                    if running {
                        Button {
                            model.core?.cancel(dir)
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.secondary)
                        .help("停止")
                    } else if !readOnly, model.core?.pipeline.bundleNeedsContinuation(data.state) == true {
                        Button {
                            model.core?.run(dir)
                        } label: {
                            Label("继续", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.primary)
                        .help("继续")
                    }
                    Button { go(-1) } label: { Label("上一个", systemImage: "chevron.up") }
                            .labelStyle(.titleAndIcon)
                            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                            .help("上一个项目（⌥⌘↑）")
                            .disabled(neighbor(-1) == nil)
                    Button { go(1) } label: { Label("下一个", systemImage: "chevron.down") }
                            .labelStyle(.titleAndIcon)
                            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                            .help("下一个项目（⌥⌘↓）")
                            .disabled(neighbor(1) == nil)

                    Menu {
                        Button("在访达中打开") { model.open(dir) }
                        if !readOnly { Button("改软件名…") { renameOpen = true }.disabled(running) }
                        if data.submitted {
                            Button("取消已提交") { setSubmitted(false) }
                        } else if !data.historyReadOnly {
                            Button("标记为已提交") { setSubmitted(true) }.disabled(running)
                        }
                        if !readOnly {
                            Button("从头重做…", systemImage: "arrow.clockwise") { regenerateConfirm = true }.disabled(running)
                        }
                        Divider()
                        Button("从列表移除…") { removeConfirm = true }.disabled(running)
                    } label: {
                        Label("更多", systemImage: "ellipsis").labelStyle(.titleAndIcon)
                    }

                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.sm)

            PageScroll {
                if contentReady {
                    HStack(spacing: Spacing.xs) {
                        if data.state["bundleUpdating"].isTruthy { TagView(text: "交付包更新中", tone: .blue) }
                        if data.origin == "imported" { TagView(text: "历史") }
                        Spacer()
                    }
                    if data.submitted {
                        Banner(.info, "已提交，只能查看", message: "\(data.submittedAt.map { "标记于 \(formatTime($0))。" } ?? "")不能运行、改文字、改图或换模板，批量操作也会跳过它。要修改请先取消已提交。") {
                            Button("取消已提交") { setSubmitted(false) }.buttonStyle(.secondary)
                        }
                    } else if data.historyReadOnly {
                        Banner(.info, "这个旧项目只有交付包，没有文案和截图源文件，只能查看。")
                    }
                    if model.codeBatch?.current == dir {
                        Banner(.info, "正在更新这个项目的代码材料…", message: "重排代码 Word、PDF 和 TXT 开头，几秒钟。")
                    } else if model.codeBatch?.pending.contains(dir) == true {
                        Banner(.info, "排在更新代码材料的队伍里，轮到它时会自动处理")
                    }
                    if let lastError = data.state["lastError"]?.string, !running, !data.submitted {
                        let error = splitDiagnostics(lastError)
                        Banner(.error, "需要处理", message: error.text) {
                            if let path = error.path, FS.exists(path) {
                                Button("查看诊断文件") { model.open(path) }.buttonStyle(.secondary)
                            }
                        }
                    }
                    if let error = data.state["bundleUpdateError"]?.string, !data.readOnly {
                        Banner(.error, "交付包更新失败", message: error) {
                            Button("重试") { Task { await model.core?.retryBundleUpdate(dir) } }
                        }
                    } else if model.core?.pipeline.bundleNeedsContinuation(data.state) == true, !running {
                        Banner(.warning, "交付包待更新", message: "需要继续：\(STEP_ORDER.filter { !["receipt", "build"].contains($0) && !["done", "skipped"].contains(data.stepStatus($0)) }.map { UI_STEP_LABELS[$0] ?? $0 }.joined(separator: "、"))（可能调用 AI）") {
                            Button("继续") { model.core?.run(dir) }.buttonStyle(.primary)
                        }
                    }
                    if let notice = data.state["bundleUpdateNotice"]?.string {
                        Banner(.warning, notice)
                    }
                    if let step = waitingStep, step != "build", !running {
                        Banner(.warning, step == "plan" ? "界面规划已生成，请在「规划」里检查，确认后继续生图" : data.stepMessage(step) ?? "「\(UI_STEP_LABELS[step] ?? step)」等待确认") {
                            if step == "plan" {
                                Button("确认规划，继续") {
                                    Task { await model.perform { _ = try await model.core?.pipeline.confirmPlan(dir) } }
                                }
                                .buttonStyle(.primary)
                            } else {
                                Button("去确认截图") { tab = .editor }
                                    .buttonStyle(.secondary)
                            }
                        }
                    }
                    if let live {
                        LivePanel(live: live, data: data)
                    }
                    switch activeTab {
                    case .overview:
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            OverviewTab(data: data, running: running, onChanged: refresh)
                            if !readOnly {
                                HStack(spacing: Spacing.sm) {
                                    Button(data.pendingFeedback.isEmpty ? "批量修改意见" : "批量修改意见（\(data.pendingFeedback.count)）", systemImage: "text.bubble") { feedbackOpen.toggle() }
                                }
                            }
                        }
                    case .plan: PlanTab(data: data, running: running, onChanged: refresh)
                    case .editor: EditorTab(data: data, running: running, onChanged: refresh)
                    case .delivery: DeliveryTab(data: data, running: running, onChanged: refresh)
                    }
                } else {
                    Text("正在载入内容…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: Metrics.gridShotHeight)
                }
            }
            .task {
                // 工具栏布局完成后再挂载正文，避免同一帧创建全部编辑控件。
                guard !contentReady else { return }
                try? await Task.sleep(for: .milliseconds(50))
                if !Task.isCancelled { contentReady = true }
            }
        }
        .sheet(isPresented: $renameOpen) {
            RenameSheet(dir: dir, name: data.name)
        }
        .alert("从头重做「\(data.name)」？", isPresented: $regenerateConfirm) {
            Button("从头重做", role: .destructive) { regenerate(data) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧的规划、截图和说明先归档到项目的 archive 文件夹，交付包在重新出包时归档，然后从头重新规划、生图、写说明。屏数、重点、补充说明不变，日期按今天算；代码来源不变。")
        }
        .confirmationDialog("移除「\(data.name)」？", isPresented: $removeConfirm, titleVisibility: .visible) {
            Button("只从列表移除") { remove(deleteFolder: false) }
            Button("移除并把文件夹移到废纸篓", role: .destructive) { remove(deleteFolder: true) }
        } message: {
            Text("只从列表移除：项目文件夹留在原处，以后可以在「设置 → 导入项目」里重新导入。\n移到废纸篓：项目文件夹（截图、文档、交付包）一起移到废纸篓，清空废纸篓前都可以恢复。")
        }
    }

    /// 从头重做：沿用这个项目的屏数、重点、补充说明、平台，日期按今天
    func regenerate(_ data: ProjectData) {
        Task {
            if await model.perform("已开始从头重做，旧文件已归档", { try await model.core?.regenerateProject(dir) }) {
                await model.reloadProjects()
                await reload()
            }
        }
    }

    func remove(deleteFolder: Bool) {
        Task {
            if await model.perform(deleteFolder ? "已移除，项目文件夹已移到废纸篓" : "已从列表移除", { try await model.core?.removeFromList(dir, deleteFolder: deleteFolder) }) {
                await model.reloadProjects()
                model.projectPath = []
            }
        }
    }
}

/// 改软件名：不重新规划和生图；用新名字重新验收截图，再重建交付包。
struct RenameSheet: View {
    let dir: String
    let name: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("改软件名").font(.title2.weight(.semibold))
            Text("不会重新规划和生图；会用新名字重新检查截图，再重建交付包。").foregroundStyle(.secondary)
            TextField("软件名（含版本号）", text: $value).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("改名") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            guard let core = model.core else { return }
                            let newDir = try await core.renameSoftware(dir, value.jsTrimmed)
                            dismiss()
                            model.toast(.success, "已改名。截图会按新名字重新检查，然后重建交付包。")
                            await model.reloadProjects()
                            model.projectPath = [newDir]
                            core.run(newDir)
                        } catch {
                            model.toast(.error, messageOf(error))
                        }
                    }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || value.jsTrimmed.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .onAppear { value = name }
    }
}
