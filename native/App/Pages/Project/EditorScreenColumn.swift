import StudioCore
import SwiftUI

extension EditorTab {
    func screenColumn(_ screen: ScreenItem) -> some View {
        let gate = screen.gate
        let tag = gateTag(gate)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                if let file = screen.file {
                    ScreenImage(path: file, version: screen.mtime).id(screen.id)
                        .overlay(Radius.shape(Radius.large).strokeBorder(Palette.screenshotEdge, lineWidth: Palette.hairline))
                        .onTapGesture { preview = screen }
                        // 和访达一样：选中（Tab 键移过来）后按空格看大图
                        .focusable()
                        .focusEffectDisabled(false)
                        .onKeyPress(.space) { preview = screen; return .handled }
                        .help("点击或按空格查看大图")
                } else {
                    Rectangle().fill(.quaternary)
                    Text(running ? "生成中…" : "未生成").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: Metrics.gridShotHeight)
            .frame(maxWidth: Metrics.editorImageWidth)
            .background(Palette.fill.color)
            .clipShape(RoundedRectangle(cornerRadius: Radius.large))
            FlowLayout(spacing: Spacing.xs) {
                TagView(text: tag.0, tone: tag.1)
                if screen.state["promptEdited"].isTruthy && data.origin != "imported" { TagView(text: "提示词已改", tone: .purple) }
            }
            if ["failed", "error"].contains(gate?["status"]?.string ?? "") {
                Text(gate?["reasons"].items.map(\.jsString).joined(separator: "；") ?? "").textStyle(Typography.caption).foregroundStyle(Palette.danger)
            }
            if !screen.warnings.isEmpty {
                Text("\(screen.warnings.count) 条提醒").textStyle(Typography.caption).foregroundStyle(Palette.warning).help(screen.warnings.map { "• \($0)" }.joined(separator: "\n"))
            }
            if gate?["status"]?.string == "needs-manual", !data.readOnly {
                HStack {
                    Button("没有软件名，通过") { manual(screen, true) }.buttonStyle(.primary).controlSize(.small)
                    Button("不合格", role: .destructive) { manual(screen, false) }.controlSize(.small)
                }
                .disabled(!editable)
            }
            if !data.readOnly {
                HStack(spacing: Spacing.xs) {
                    Button { history = screen } label: {
                        HStack(spacing: Spacing.xs) {
                            Label("以前的截图", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
                            if !screen.history.isEmpty { Text("\(screen.history.count)") }
                        }
                    }
                    .help(screen.history.isEmpty ? "还没有以前的截图" : "以前的截图 \(screen.history.count) 张，可以换回")
                    .disabled(screen.history.isEmpty)
                    Button { alternates = screen } label: {
                        HStack(spacing: Spacing.xs) {
                            Label("备选图", systemImage: "arrow.left.arrow.right").labelStyle(.iconOnly)
                            if !screen.alternates.isEmpty { Text("\(screen.alternates.count)") }
                        }
                    }
                    .help(screen.alternates.isEmpty ? "没有备选图" : "备选图 \(screen.alternates.count) 张")
                    .disabled(screen.alternates.isEmpty)
                    Spacer()
                    Menu {
                        Button("查看大图") { preview = screen }.disabled(screen.file == nil)
                        Button("以前的截图…") { history = screen }.disabled(screen.history.isEmpty)
                        Button("查看 / 编辑提示词") { promptEdit = screen }
                        Divider()
                        Button("人工确认：没有软件名") { manual(screen, true) }
                        Button("人工判定：不合格") { manual(screen, false) }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .disabled(!editable)
            }
        }
    }

}
