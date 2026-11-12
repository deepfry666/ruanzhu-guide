import StudioCore
import SwiftUI

func gateTag(_ gate: JSON?) -> (String, Tone) {
    guard let gate else { return ("未检查", .neutral) }
    switch gate["status"]?.string ?? "" {
    case "passed": return (gate["method"]?.string == "imported-receipt" ? "沿用历史核对记录" : "检查通过", .green)
    case "manual-passed": return ("人工确认通过", .green)
    case "failed": return ("检查没通过", .red)
    case "needs-manual": return ("待人工确认", .orange)
    case "error": return ("检查出错", .red)
    default: return (gate["status"].text, .neutral)
    }
}

struct ScreenPreviewSheet: View {
    let screen: ScreenItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let gate = screen.gate
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text("\(screen.id) · \(screen.title)").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).help("关闭（Esc 或空格）")
            }
            HStack(alignment: .top, spacing: Spacing.xl) {
                ScreenImage(path: screen.file, version: screen.mtime, maxPixel: 2000)
                    .frame(width: 340)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        SettingsGroup {
                            SettingsRow(label: "检查") { let tag = gateTag(gate); TagView(text: tag.0, tone: tag.1) }
                            SettingsRow(label: "线路") { Text("\(screen.state["providerName"]?.string ?? "—")\(screen.state["model"]?.string.map { "（\($0)）" } ?? "")") }
                            SettingsRow(label: "尺寸") { Text(screen.state["width"]?.int.map { "\($0)×\(screen.state["height"]?.int ?? 0)" } ?? "—") }
                            SettingsRow(label: "生成时间") { Text(formatTime(screen.state["generatedAt"]?.string)) }
                        }
                        if let inventory = gate?["inventory"]?.string {
                            Text("看图模型抄录的界面内容").font(.headline)
                            Text(inventory).textSelection(.enabled)
                        }
                        if let visible = gate?["visibleText"]?.array, !visible.isEmpty {
                            Text("可见文字：\(visible.map(\.jsString).joined(separator: " · "))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 960, height: 760)
        .onKeyPress(.space) { dismiss(); return .handled }
    }
}

struct PromptSheet: View {
    let screen: ScreenItem
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("\(screen.id) 的生图提示词").font(.title2.weight(.semibold))
            Text("末尾的「不要渲染软件名」禁令由程序自动保留，删掉也会被加回去。").foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .padding(Spacing.xs)
                .cardBackground(cornerRadius: Radius.small)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(text) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 820, height: 600)
        .onAppear { text = screen.prompt }
    }
}

struct AlternatesSheet: View {
    let screen: ScreenItem
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("\(screen.id) 的备选图").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("另一条线路同时出的备选图，换上后要重新检查。").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.lg)], spacing: Spacing.lg) {
                    ForEach(screen.alternates, id: \.self) { item in
                        VStack(spacing: Spacing.sm) {
                            ScreenImage(path: item["file"]?.string).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                            Button("用这张") { onUse(item["file"]?.string ?? "") }
                        }
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760, height: 560)
    }
}

/// 以前用过的截图：重新生成、换备选图时旧图存在项目的 archive 文件夹，这里可以换回
struct ScreenHistorySheet: View {
    let screen: ScreenItem
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("\(screen.id) 以前的截图").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("换回后要重新检查，这一屏的说明会按换回的截图重写（人工改过的除外）。现在这张也会存进来，随时能再换。").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)], spacing: Spacing.lg) {
                    VStack(spacing: Spacing.sm) {
                        ScreenImage(path: screen.file, version: screen.mtime).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                        Text("现在用的").font(.caption.weight(.semibold))
                    }
                    ForEach(Array(screen.history.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: Spacing.sm) {
                            ScreenImage(path: item["file"]?.string).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                            Text(formatTime(item["at"]?.string)).font(.caption).foregroundStyle(.secondary)
                            Button("换回这张") { onUse(item["file"]?.string ?? "") }
                        }
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 820, height: 620)
    }
}
