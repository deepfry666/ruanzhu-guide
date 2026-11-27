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
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(Metrics.sidebarWidth)
        } detail: {
            WorkspaceDetail()
        }
        .modifier(BatchModificationPresentation())
    }
}

/// 保留原生表格与分栏，项目导航只在内容层观察。
private struct WorkspaceDetail: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            ProjectWorkspace()
                .opacity(model.section == .projects || model.section == nil ? 1 : 0)
                .allowsHitTesting(model.section == .projects || model.section == nil)
                .accessibilityHidden(model.section != .projects && model.section != nil)
            switch model.section ?? .projects {
            case .projects: EmptyView()
            case .models: NavigationStack { ModelsView() }
            case .stats: NavigationStack { StatsView() }
            case .settings: NavigationStack { SettingsView() }
            }
        }
        .overlay(alignment: .bottom) { PendingJobsNotice() }
    }
}

private struct ProjectWorkspace: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        GeometryReader { viewport in
            ZStack {
                ProjectsView()
                if (model.section == .projects || model.section == nil), let dir = model.projectPath.last {
                    ProjectDetailView(dir: dir).id(dir)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .navigationTitle((AppModel.isTrial ? "试用 · " : "") + "项目")
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
                .foregroundStyle(Palette.textSecondary)
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
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).textStyle(Typography.title)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("有 \(jobs.count) 个生图任务在提交途中软件退出了，不确定中转站是否已经扣费").textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                    Text("这些屏会在下次运行时重新生成。如果你在中转站后台确认已出图，可以忽略。").textStyle(Typography.body).foregroundStyle(Palette.textSecondary)
                }
                Button("知道了") {
                    Task {
                        for job in jobs { await model.core?.dismissJob(job["jobId"]?.string ?? "") }
                        model.reloadPendingJobs()
                    }
                }
                .buttonStyle(.secondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: Metrics.dialogNewWidth)
            .surface(Radius.large)
            .elevation(.raised, in: Radius.shape(Radius.large))
            .padding(Spacing.xl)
        }
    }
}
