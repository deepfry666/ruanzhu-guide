import SwiftUI

extension Tone {
    /// 规范只有 4 个状态色，其余都是灰阶：运行中、意见 → 信息；已完成 → 成功；等待、提醒 → 警告；
    /// 需要处理 → 失败；已提交、只读、人工改过等 → 中性。
    var swatch: Swatch {
        switch self {
        case .neutral, .purple: Palette.textSecondary
        case .blue, .cyan: Palette.info
        case .green: Palette.success
        case .orange, .gold: Palette.warning
        case .red: Palette.danger
        }
    }

    var isNeutral: Bool { swatch == Palette.textSecondary }
}

/// 小标签（状态、来源、提醒）：高 20，左右内边距 8，圆角小，辅助加粗。
/// 有颜色的标签：状态浅底 + 同色文字；中性标签：填充底 + 次要文字。
struct TagView: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .textStyle(Typography.captionStrong)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: Metrics.tagHeight)
            .foregroundStyle(tone.swatch)
            .background(tone.isNeutral ? Palette.fill : tone.swatch.tint, in: Radius.shape(Radius.small))
    }
}

/// 状态点 + 文字（系统设置里的样式）。
struct StatusDot: View {
    enum Kind { case ok, warn, error, idle }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle().fill(swatch).frame(width: 7, height: 7)
            Text(text)
        }
    }

    var swatch: Swatch {
        switch kind {
        case .ok: Palette.success
        case .warn: Palette.warning
        case .error: Palette.danger
        case .idle: Palette.textSecondary
        }
    }
}

/// 页面顶部的提示条：状态浅底，左边状态色图标。
struct Banner<Actions: View>: View {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    init(_ kind: Kind, _ title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var swatch: Swatch {
        switch kind {
        case .info: Palette.info
        case .success: Palette.success
        case .warning: Palette.warning
        case .error: Palette.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Metrics.icon))
                .frame(width: Metrics.icon, height: Typography.bodyStrong.lineHeight)
                .foregroundStyle(swatch)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                if let message, !message.isEmpty {
                    Text(message).textStyle(Typography.body).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: Spacing.sm)
            actions()
        }
        .padding(Spacing.md)
        .background(swatch.tint, in: Radius.shape(Radius.medium))
    }
}

extension Banner where Actions == EmptyView {
    init(_ kind: Kind, _ title: String, message: String? = nil) {
        self.init(kind, title, message: message) { EmptyView() }
    }
}

/// 空状态。
struct EmptyHint: View {
    let title: String
    var systemImage = "tray"
    var message: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}
