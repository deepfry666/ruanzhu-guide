import AppKit
import StudioCore
import SwiftUI

extension ProjectsView {
    /// 保留原生表格实例，避免外观变化与表格销毁同时触发系统协调器错误。
    var projectPresentation: some View {
        ZStack {
            table
                .opacity(presentation == "grid" ? 0 : 1)
                .allowsHitTesting(presentation != "grid")
                .accessibilityHidden(presentation == "grid")
            if gridMounted {
                grid
                    .opacity(presentation == "grid" ? 1 : 0)
                    .allowsHitTesting(presentation == "grid")
                    .accessibilityHidden(presentation != "grid")
            }
        }
    }

    var gridInteractive: Bool {
        presentation == "grid" && model.projectPath.isEmpty && (model.section == .projects || model.section == nil)
    }

    var grid: some View {
        GeometryReader { viewport in
            let columnWidth = Metrics.sidebarWidth + Spacing.xl
            let columns = max(1, Int((viewport.size.width - Spacing.xl * 2 + Spacing.lg) / (columnWidth + Spacing.lg)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: Spacing.lg)], spacing: Spacing.lg) {
                        ForEach(rows) { row in gridCard(row).id(row.dir) }
                    }
                    .padding(Spacing.xl)
                    .background(GridScrollIdentity())
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { key in
                    guard gridInteractive, !rows.isEmpty else { return .ignored }
                    let step = key.key == .upArrow ? -columns : key.key == .downArrow ? columns : key.key == .leftArrow ? -1 : 1
                    let current = rows.firstIndex { $0.dir == lastClicked } ?? rows.firstIndex { selection.contains($0.dir) }
                    let next = current.map { min(rows.count - 1, max(0, $0 + step)) } ?? 0
                    let dir = rows[next].dir
                    selectGrid(dir, modifiers: key.modifiers, keyboard: true)
                    proxy.scrollTo(dir)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard gridInteractive, selection.count == 1, let dir = selection.first else { return .ignored }
                    model.openProject(dir)
                    return .handled
                }
                .onKeyPress(keys: ["a"]) { key in
                    guard gridInteractive, key.modifiers.contains(.command) else { return .ignored }
                    selection = Set(rows.map(\.dir)); checkMode = true
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard gridInteractive, !selection.isEmpty else { return .ignored }
                    askRemove(selectedRows)
                    return .handled
                }
                .onExitCommand { if gridInteractive { clearSelection() } }
                .safeAreaInset(edge: .bottom, spacing: 0) { if !selection.isEmpty { selectionBar } }
                .overlay {
                    if model.projectsLoaded && rows.isEmpty {
                        EmptyHint(title: model.projects.isEmpty ? "还没有项目" : "没有符合条件的项目", systemImage: "square.grid.2x2",
                                  message: model.projects.isEmpty ? "点工具栏「新建」或按 ⌘N 创建。" : nil)
                    }
                }
            }
        }
    }

    func gridCard(_ row: ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ProjectThumbnailView(thumbnail: row.thumbnail, height: Metrics.gridShotHeight)
                .frame(height: Metrics.gridShotHeight)
                .surface(Radius.small, fill: Palette.fill)
            HStack(alignment: .top, spacing: Spacing.sm) {
                Toggle("选择项目", isOn: Binding(get: { selection.contains(row.dir) }, set: {
                    if $0 { selection.insert(row.dir); checkMode = true } else { selection.remove(row.dir) }
                    gridAnchor = row.dir; lastClicked = row.dir; gridFocused = true
                })).toggleStyle(.checkbox).labelsHidden()
                Text(row.name).textStyle(Typography.bodyStrong).lineLimit(2).help(row.name)
            }
            FlowLayout(spacing: Spacing.xs) { ForEach(rowTags(row), id: \.0) { TagView(text: $0.0, tone: $0.1) } }
            statusTag(row)
            ProgressCell(row: row).textStyle(Typography.caption)
            Text(row.bundleFiles.map { "交付 \($0) 个文件" } ?? (row.hasBundle ? "已有交付包" : "尚无交付包"))
                .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            Text(row.recency > 0 ? "最近动过：\(formatTime(ms: row.recency * 1000))" : "尚无时间记录")
                .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface(fill: selection.contains(row.dir) ? Palette.primary.tint : Palette.card)
        .overlay(Radius.shape(Radius.large).strokeBorder(selection.contains(row.dir) ? Palette.primary : Palette.divider, lineWidth: Palette.hairline))
        .contentShape(Radius.shape(Radius.large))
        .hoverLift()
        .onTapGesture {
            guard gridInteractive, (NSApp.currentEvent?.clickCount ?? 1) < 2 else { return }
            beforeClick = selection
            selectGrid(row.dir, modifiers: EventModifiers(event: NSApp.currentEvent))
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard gridInteractive else { return }
            if let beforeClick, checkMode || beforeClick.count > 1 { selection = beforeClick }
            model.openProject(row.dir)
        })
        .contextMenu { contextMenu(selection.contains(row.dir) ? selection : [row.dir]) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "打开项目") { model.openProject(row.dir) }
    }

    func selectGrid(_ dir: String, modifiers: EventModifiers, keyboard: Bool = false) {
        gridFocused = true
        let order = rows.map(\.dir)
        if modifiers.contains(.shift), let anchor = gridAnchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: dir) {
            let range = Set(order[min(start, end)...max(start, end)])
            selection = modifiers.contains(.command) ? selection.union(range) : range
        } else if modifiers.contains(.command) || (!keyboard && (checkMode || selection.count > 1)) {
            selection = selection.contains(dir) ? selection.subtracting([dir]) : selection.union([dir])
            gridAnchor = dir
        } else {
            selection = [dir]
            gridAnchor = dir
        }
        lastClicked = dir
    }
}

private extension EventModifiers {
    init(event: NSEvent?) {
        self = []
        if event?.modifierFlags.contains(.command) == true { insert(.command) }
        if event?.modifierFlags.contains(.shift) == true { insert(.shift) }
    }
}

/// 给真实网格滚动容器标识，供同一测量指令滚动；不产生滚动或修改数据。
private struct GridScrollIdentity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.enclosingScrollView?.identifier = NSUserInterfaceItemIdentifier("project-grid-scroll") }
    }
}
