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
                MainSplitView()
            }
        }
        .overlay(alignment: .top) { ToastOverlay(toasts: model.toasts) }
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
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            Group {
                switch model.section ?? .projects {
                case .new:
                    NavigationStack { NewProjectView() }
                case .projects:
                    NavigationStack(path: $model.projectPath) {
                        ProjectsView()
                            .navigationDestination(for: String.self) { dir in
                                // 按项目区分视图：翻到上一个 / 下一个项目时重新加载，不沿用上一个项目的内容
                                ProjectDetailView(dir: dir).id(dir)
                            }
                    }
                case .models:
                    NavigationStack { ModelsView() }
                case .stats:
                    NavigationStack { StatsView() }
                case .settings:
                    NavigationStack { SettingsView() }
                }
            }
            .overlay(alignment: .bottom) { PendingJobsNotice() }
        }
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
                HStack(spacing: 10) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("软件指南生成器").font(.headline).foregroundStyle(.primary)
                        Text("截图 · 文案 · 交付包").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("v\(model.appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
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
                .buttonStyle(.glass)
            }
            .padding(16)
            .frame(maxWidth: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(20)
        }
    }
}
