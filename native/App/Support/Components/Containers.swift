import StudioCore
import SwiftUI

/// 卡片：「卡片」色底，1px 分隔线描边，圆角大，内边距 16，没有阴影。
/// 标题用正文加粗，右侧可以放辅助文字或一个文字按钮；标题和内容间距 12。
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if title != nil || trailing != nil {
                HStack(spacing: Spacing.sm) {
                    if let title { Text(title).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text) }
                    Spacer()
                    trailing
                }
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// 数值统计卡片：辅助字号的名称 + 统计大数（数字变化时滚动）。
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            Text(value)
                .textStyle(Typography.statNumber)
                .foregroundStyle(Palette.text)
                .numberRoll(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .surface()
    }
}

extension View {
    /// 卡片底（「卡片」色 + 1px 分隔线描边）；默认圆角大
    func cardBackground(cornerRadius: CGFloat = Radius.large) -> some View {
        surface(cornerRadius)
    }
}

/// 页面内容的统一外框：可滚动、四周留白 24、最大宽度居中，区块之间 16。
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 1180
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) { content() }
                .padding(Spacing.xl)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// 系统设置样式的分组：标题、卡片底、行之间有分隔线。
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if title != nil || trailing != nil {
                HStack(spacing: Spacing.sm) {
                    if let title { Text(title).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, Spacing.xs)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index]
                        if index < subviews.count - 1 {
                            Rectangle().fill(Palette.divider).frame(height: Palette.hairline).padding(.leading, Spacing.lg)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            if let footer {
                Text(footer).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary).padding(.horizontal, Spacing.xs)
            }
        }
    }
}

/// 一行一项：左边标签，右边控件。
struct SettingsRow<Control: View>: View {
    let label: String
    var hint: String? = nil
    var info: String? = nil
    var vertical = false
    @ViewBuilder var control: Control

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    RowLabel(title: label, hint: hint, info: info)
                    control
                }
            } else {
                HStack(alignment: .center, spacing: Spacing.md) {
                    RowLabel(title: label, hint: hint, info: info)
                    Spacer(minLength: Spacing.md)
                    HStack(spacing: Spacing.sm) { control }
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Control == EmptyView {
    init(label: String, hint: String? = nil, info: String? = nil) {
        self.init(label: label, hint: hint, info: info) { EmptyView() }
    }
}

/// 带说明的表单标签。
struct RowLabel: View {
    let title: String
    var hint: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(title).textStyle(Typography.body).fixedSize(horizontal: true, vertical: false)
                if let info { InfoButton(text: info) }
            }
            if let hint, !hint.isEmpty {
                Text(hint).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// ⓘ：长说明收进弹出框，不在界面上铺大段文字。
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .textStyle(Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(Spacing.lg)
        }
    }
}

/// 路径：家目录写成 ~，太长时中间省略，悬停看完整路径。
struct PathText: View {
    let path: String?
    var empty = "未设置"

    var body: some View {
        if let path, !path.isEmpty {
            Text(shortPath(path))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        } else {
            Text(empty).foregroundStyle(Palette.textSecondary)
        }
    }
}
