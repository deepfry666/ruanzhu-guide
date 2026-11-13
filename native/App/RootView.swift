import StudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView("正在启动…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("启动失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await model.launchCore() } }
                }
            case .ready:
                if model.trialMeasure {
                    // 保留列表滚动、筛选供测量；所有修改入口均无核心服务可调用。
                    NavigationStack { ProjectsView().navigationTitle("试用 · 项目") }
                        .overlay(alignment: .top) { Text("试用 · 测量模式（仅列表）").bold() }
                } else {
                    MainSplitView()
                }
            }
        }
        .sheet(isPresented: $model.newProjectPresented) {
            NewProjectView().environment(model).designSystem()
                .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        }
        .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), presenting: model.alert) { item in
            if let actionTitle = item.actionTitle, let action = item.action {
                Button(actionTitle) { action() }
                Button("关闭", role: .cancel) {}
            } else {
                Button("好") {}
            }
        } message: { item in
            Text(item.message)
        }
    }
}

struct MainSplitView: View {
    @State private var feedbackOpen = false
    @State private var feedbackData: ProjectData?

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(Metrics.sidebarWidth)
        } detail: {
            WorkspaceDetail(feedbackOpen: $feedbackOpen, feedbackData: $feedbackData)
        }
        .inspector(isPresented: $feedbackOpen) {
            if feedbackOpen, let data = feedbackData {
                ProjectFeedbackInspector(data: data)
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 560)
            }
        }
    }
}

/// 项目路径只由内容层观察，不让列表与详情切换重建外层分栏。
private struct WorkspaceDetail: View {
    @Environment(AppModel.self) private var model
    @Binding var feedbackOpen: Bool
    @Binding var feedbackData: ProjectData?

    var body: some View {
        ZStack {
            // 保留原生表格，避免切换外观时销毁仍有待处理更新的表格协调器。
            ProjectWorkspace(feedbackOpen: $feedbackOpen, feedbackData: $feedbackData)
                .opacity(model.section == .projects || model.section == nil ? 1 : 0)
                .allowsHitTesting(model.section == .projects || model.section == nil)
                .accessibilityHidden(model.section != .projects && model.section != nil)
            switch model.section ?? .projects {
            case .projects:
                EmptyView()
            case .models:
                NavigationStack { ModelsView() }
            case .stats:
                NavigationStack { StatsView() }
            case .settings:
                NavigationStack { SettingsView() }
            }
        }
        .overlay(alignment: .bottom) { PendingJobsNotice() }
        .onChange(of: model.projectPath) { _, _ in
            if feedbackOpen { feedbackOpen = false }
            if feedbackData != nil { feedbackData = nil }
        }
        .onChange(of: model.section) { _, _ in
            if feedbackOpen { feedbackOpen = false }
        }
    }
}

private struct ProjectWorkspace: View {
    @Environment(AppModel.self) private var model
    @Binding var feedbackOpen: Bool
    @Binding var feedbackData: ProjectData?

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                ProjectsView()
                if (model.section == .projects || model.section == nil), let dir = model.projectPath.last {
                    ProjectDetailView(dir: dir, feedbackOpen: $feedbackOpen,
                                      onInspectorData: { feedbackData = $0 }).id(dir)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .navigationTitle((AppModel.isTrial ? "试用 · " : "") + "项目")
    }
}

private struct ProjectFeedbackInspector: View {
    let data: ProjectData
    @Environment(AppModel.self) private var model

    var body: some View {
        FeedbackPanel(data: data,
                      running: data.runningFlag || data.status == "running" || model.signal(data.dir).live != nil,
                      onChanged: { model.bump(data.dir) })
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(item == .projects ? runningCount : 0)
                        .tag(item)
                }
            } header: {
                HStack(spacing: Spacing.sm) {
                    Image("Logo")
                        .resizable()
                        .frame(width: Metrics.segmentedHeight, height: Metrics.segmentedHeight)
                    Text(model.displayName).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                }
                .padding(.vertical, Spacing.sm)
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("v\(model.appVersion)")
                .textStyle(Typography.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.md)
        }
        .onChange(of: model.section) { _, next in
            if next == .projects { model.projectPath = [] }
        }
    }

    var runningCount: Int { model.projects.filter { $0.status == "running" }.count }
}

/// 提交途中退出、不确定是否已扣费的生图任务。
struct PendingJobsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.unknownJobs
        if !jobs.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("有 \(jobs.count) 个生图任务在提交途中软件退出了，不确定中转站是否已经扣费").fontWeight(.semibold)
                    Text("这些屏会在下次运行时重新生成。如果你在中转站后台确认已出图，可以忽略。").font(.callout).foregroundStyle(.secondary)
                }
                Button("知道了") {
                    Task {
                        for job in jobs { await model.core?.dismissJob(job["jobId"]?.string ?? "") }
                        model.reloadPendingJobs()
                    }
                }
                .buttonStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(20)
        }
    }
}
