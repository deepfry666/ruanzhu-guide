import StudioCore
import SwiftUI

/// 设置 → 清理空间：先扫描，勾选后才清理，清理的内容都移到废纸篓。
struct CleanupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var scan: CleanupScan?
    @State private var scanning = false
    @State private var running = false
    @State private var selected = Set<String>()
    @State private var expanded = Set<String>()
    @State private var confirming = false
    @State private var lastResult: CleanupResult?

    private var groups: [CleanupGroup] { scan?.groups ?? [] }
    private var chosen: [CleanupGroup] { groups.filter { selected.contains($0.id) } }
    private var chosenBytes: Int { chosen.reduce(0) { $0 + $1.bytes } }
    private var chosenItems: Int { chosen.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            if let result = lastResult { resultBanner(result) }
            if let scan, scan.busyProjects > 0 {
                Banner(.info, "有 \(scan.busyProjects) 个项目正在运行或排队，已跳过", message: "等它们跑完再扫描一次，就能一起清理。")
            }
            let first = groups.filter { $0.kind.tier == 1 }
            let second = groups.filter { $0.kind.tier == 2 }
            if scan != nil, groups.isEmpty {
                SettingsGroup { SettingsRow(label: "没有可清理的内容", hint: "项目里没有旧流程的临时文件夹，归档里也没有超过 \(CLEANUP_ARCHIVE_DAYS) 天的旧版本。") }
            }
            if !first.isEmpty {
                SettingsGroup(title: "不影响成果的旧文件（默认勾选）", footer: "这些是旧流程留下的临时文件夹，当前版本不会再用到。清理后在废纸篓里还能找回。") {
                    ForEach(first) { row($0) }
                }
            }
            if !second.isEmpty {
                SettingsGroup(title: "超过 \(CLEANUP_ARCHIVE_DAYS) 天的旧版本（默认不勾选）", footer: "清理后不能再换回这些旧截图和旧文件。\(CLEANUP_ARCHIVE_DAYS) 天以内的归档不会动。") {
                    ForEach(second) { row($0) }
                }
            }
            if !groups.isEmpty { actionBar }
            Text("不会动的：截图、规划和文案、提示词、交付文件夹和压缩包、\(CLEANUP_ARCHIVE_DAYS) 天以内的归档、没有导入到软件里的项目文件夹、软件自己的数据。")
                .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary).padding(.horizontal, Spacing.xs)
        }
        .task { await refresh() }
        .onChange(of: model.devCleanup) { _, command in handleDev(command) }
        .confirmationDialog("把选中的 \(chosenItems) 项移到废纸篓？", isPresented: $confirming, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) { Task { await runCleanup() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(sizeText(chosenBytes))。可以在废纸篓里恢复；旧截图和旧文件清理后，软件里不能再换回。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("清理空间").textStyle(Typography.title).foregroundStyle(Palette.text)
                Text("扫描各项目和工作区里可以清理的内容。扫描只读文件，勾选并确认后才会清理。")
                    .textStyle(Typography.body).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if scanning { ProgressView().controlSize(.small) }
            Button("重新扫描") { Task { await refresh() } }.disabled(scanning || running)
        }
    }

    private func row(_ group: CleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Toggle("", isOn: Binding(get: { selected.contains(group.id) }, set: { on in
                    if on { selected.insert(group.id) } else { selected.remove(group.id) }
                }))
                .toggleStyle(.checkbox).labelsHidden().disabled(running)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title(group)).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                    Text(detail(group)).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.md)
                Text(sizeText(group.bytes)).textStyle(Typography.body.number).foregroundStyle(Palette.textSecondary)
                if group.items.count > 1 || group.kind != .workspaceLeftover {
                    Button(expanded.contains(group.id) ? "收起" : "明细") {
                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    }
                    .buttonStyle(.textAction)
                }
            }
            if expanded.contains(group.id) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(group.items.prefix(60)) { item in
                        HStack(spacing: Spacing.sm) {
                            Text(itemLabel(item)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Spacing.sm)
                            Text(sizeText(item.bytes)).textStyle(Typography.caption.number)
                        }
                        .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                    if group.items.count > 60 {
                        Text("另有 \(group.items.count - 60) 项…").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.leading, Spacing.xl)
            }
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.sm) {
            Text(selected.isEmpty ? "还没有勾选" : "已选 \(chosenItems) 项，可腾出 \(sizeText(chosenBytes))")
                .textStyle(Typography.body).foregroundStyle(Palette.textSecondary)
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button("移到废纸篓…") { confirming = true }
                .buttonStyle(.primary)
                .disabled(selected.isEmpty || running || scanning || model.trialMeasure)
        }
        .padding(.horizontal, Spacing.xs)
    }

    private func resultBanner(_ result: CleanupResult) -> some View {
        let problems = result.failed.map { "\($0.item.name)：\($0.message)" } + (result.skipped.isEmpty ? [] : ["有 \(result.skipped.count) 项已不在扫描结果里或项目刚开始运行，没有动。"])
        return Banner(problems.isEmpty ? .success : .warning, "已把 \(result.trashed.count) 项移到废纸篓，腾出 \(sizeText(result.bytes))", message: problems.joined(separator: "\n"))
    }

    private func title(_ group: CleanupGroup) -> String {
        switch group.kind {
        case .projectTemp: "各项目里的临时文件夹"
        case .workspaceLeftover: "工作区里的「\(group.items.first?.name ?? "")」文件夹"
        case .oldScreens: "旧截图"
        case .oldHandEdits: "手改保留的旧文件"
        }
    }

    private func detail(_ group: CleanupGroup) -> String {
        switch group.kind {
        case .projectTemp:
            "\(CLEANUP_PROJECT_DIRS.joined(separator: "、"))，共 \(group.items.count) 个文件夹，来自 \(group.projectCount) 个项目"
        case .workspaceLeftover:
            "旧流程留在项目存放位置根目录下的文件夹，里面没有截图和项目内容，没有导入到软件里"
        case .oldScreens:
            "重新生成、换图时归档的截图，\(CLEANUP_ARCHIVE_DAYS) 天前的，共 \(group.items.count) 次归档，来自 \(group.projectCount) 个项目。清理后「以前的截图」里不再有它们"
        case .oldHandEdits:
            "更新交付包前另存的、你在软件外手改过的旧文件，\(CLEANUP_ARCHIVE_DAYS) 天前的，共 \(group.items.count) 份，来自 \(group.projectCount) 个项目"
        }
    }

    private func itemLabel(_ item: CleanupItem) -> String {
        guard let name = item.projectName else { return "工作区 / \(item.name)" }
        return "\(name) / \(item.kind == .projectTemp ? item.name : "archive/" + item.name)"
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: 动作

    private func refresh() async {
        guard let core = model.core else { return }
        scanning = true
        defer { scanning = false }
        do {
            let next = try await core.scanCleanup()
            scan = next
            selected = Set(next.groups.filter(\.kind.defaultChecked).map(\.id))
        } catch {
            model.toast(.error, messageOf(error))
        }
    }

    private func runCleanup() async {
        guard let core = model.core, !model.trialMeasure else { return }
        let paths = chosen.flatMap(\.items).map(\.path)
        running = true
        defer { running = false }
        do {
            lastResult = try await core.runCleanup(paths)
            await refresh()
        } catch {
            model.toast(.error, messageOf(error))
        }
    }

    /// 试用版验证用（DevControl）：select:tier1|tier2|all|none 改勾选，run 直接清理（只在试用版生效）
    private func handleDev(_ command: String?) {
        guard AppModel.isTrial, let command = command?.split(separator: "#").first.map(String.init) else { return }
        if command.hasPrefix("select:") {
            let which = String(command.dropFirst(7))
            let ids = groups.filter { which == "all" || (which == "tier1" && $0.kind.tier == 1) || (which == "tier2" && $0.kind.tier == 2) }.map(\.id)
            selected = Set(ids)
            expanded = Set(ids)
        } else if command == "run" {
            Task { await runCleanup() }
        } else if command == "rescan" {
            Task { await refresh() }
        }
    }
}
