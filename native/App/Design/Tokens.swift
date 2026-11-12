import AppKit
import SwiftUI

// 视觉规范（#6 定稿）的全部数值。界面里的颜色、字号、间距、圆角、阴影只从这里取；
// 这里没有的，先补进规范再加到这里。

// MARK: - 颜色

/// 一个浅色、深色各一份的颜色。可以直接当 ShapeStyle 用（跟随视图的浅色 / 深色），
/// 需要 `Color` 的地方（阴影、tint）用 `.color`（跟随窗口外观的动态颜色）。
nonisolated struct Swatch: ShapeStyle, Hashable, Sendable {
    struct RGBA: Hashable, Sendable {
        var red, green, blue, alpha: Double

        init(_ hex: UInt32, alpha: Double = 1) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
            self.alpha = alpha
        }

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// 混入另一种颜色（`amount` 是另一种颜色所占比例，和 CSS color-mix 相同）
        func mixed(with other: RGBA, _ amount: Double) -> RGBA {
            RGBA(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                 blue: blue + (other.blue - blue) * amount, alpha: alpha + (other.alpha - alpha) * amount)
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    }

    let light: RGBA
    let dark: RGBA

    init(_ light: UInt32, _ dark: UInt32) {
        self.light = RGBA(light)
        self.dark = RGBA(dark)
    }

    init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        (environment.colorScheme == .dark ? dark : light).color
    }

    /// 跟随窗口外观的动态颜色（给只收 `Color` 的接口用）
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        let light = light, dark = dark
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        }
    }

    /// 同一颜色、不同不透明度（浅色、深色可以不同）
    func opacity(light lightAlpha: Double, dark darkAlpha: Double) -> Swatch {
        var light = light, dark = dark
        light.alpha *= lightAlpha
        dark.alpha *= darkAlpha
        return Swatch(light: light, dark: dark)
    }

    func opacity(_ alpha: Double) -> Swatch { opacity(light: alpha, dark: alpha) }

    /// 状态浅底：叠 12%（浅色）/ 20%（深色）
    var tint: Swatch { opacity(light: Palette.tintLight, dark: Palette.tintDark) }

    /// 混入另一种颜色（例如次要按钮悬停：填充色混入 6% 主文字）
    func mixed(with other: Swatch, _ amount: Double) -> Swatch {
        Swatch(light: light.mixed(with: other.light, amount), dark: dark.mixed(with: other.dark, amount))
    }
}

/// 规范第 1 节的颜色。
nonisolated enum Palette {
    static let primary = Swatch(0x1A66D9, 0x2F80F5)
    static let primaryHover = Swatch(0x1557BF, 0x4A90F7)
    static let success = Swatch(0x147A43, 0x32C26C)
    static let warning = Swatch(0x945800, 0xF2A53A)
    static let danger = Swatch(0xC42F2F, 0xFF7A72)
    static let info = Swatch(0x08707F, 0x35C2D9)
    static let windowBackground = Swatch(0xF5F5F7, 0x1C1C1E)
    static let sidebar = Swatch(0xECECEF, 0x232326)
    static let card = Swatch(0xFFFFFF, 0x2A2A2D)
    static let fill = Swatch(0xE8E8EC, 0x38383C)
    static let divider = Swatch(0xE0E0E5, 0x3D3D42)
    static let text = Swatch(0x1D1D1F, 0xF2F2F4)
    static let textSecondary = Swatch(0x6E6E73, 0x9C9CA3)
    static let onColor = Swatch(0xFFFFFF, 0xFFFFFF)

    // 由上面推出来的（不算新颜色）
    /// 状态浅底的不透明度：浅色 12%、深色 20%
    static let tintLight = 0.12
    static let tintDark = 0.20
    /// 次要按钮悬停：填充色混入 6% 主文字
    static let secondaryHover = fill.mixed(with: text, 0.06)
    /// 列表行悬停：填充色 50% 不透明度
    static let rowHover = fill.opacity(0.5)
    /// 焦点框光圈：主色 25%，宽 3
    static let focusRing = primary.opacity(0.25)
    /// 填错光圈：失败色 20%，宽 3
    static let errorRing = danger.opacity(0.20)
    static let ringWidth: CGFloat = 3
    /// 禁用：整个控件 40% 不透明度
    static let disabledOpacity = 0.4
    /// 分段控件的选中块
    static let segmentThumb = Swatch(0xFFFFFF, 0x5A5A60)
    /// 骨架闪光的高光
    static let skeletonHighlight = Swatch(0xF6F6F8, 0x4A4A50)
    /// 弹窗遮罩：黑色 20% / 45%
    static let scrim = Swatch(light: .init(0x000000, alpha: 0.20), dark: .init(0x000000, alpha: 0.45))
    /// 浅色下截图外的 1px 描边：黑色 8%（深色不描）
    static let screenshotEdge = Swatch(light: .init(0x000000, alpha: 0.08), dark: .init(0x000000, alpha: 0))
    /// 描边、分隔线的粗细
    static let hairline: CGFloat = 1
}

// MARK: - 字号

/// 规范第 2 节：字号 / 字重 / 行高。字体一律用系统字体。
nonisolated enum Typography {
    struct Style: Sendable {
        let size: CGFloat
        let weight: Font.Weight
        let lineHeight: CGFloat
        var monospacedDigits = false

        var font: Font {
            let font = Font.system(size: size, weight: weight)
            return monospacedDigits ? font.monospacedDigit() : font
        }

        /// 数字（等宽）：跟随所在级别，字重 500
        var number: Style { Style(size: size, weight: .medium, lineHeight: lineHeight, monospacedDigits: true) }

        /// 要补到 SwiftUI 默认行高上的行距
        var lineSpacing: CGFloat {
            let font = NSFont.systemFont(ofSize: size)
            return max(0, lineHeight - (font.ascender - font.descender + font.leading).rounded(.up))
        }
    }

    /// 标题 17 / 600 / 24：页面标题、弹窗标题（≈ `.title2.weight(.semibold)`）
    static let title = Style(size: 17, weight: .semibold, lineHeight: 24)
    /// 正文 13 / 400 / 20（≈ `.body`）
    static let body = Style(size: 13, weight: .regular, lineHeight: 20)
    /// 正文加粗 13 / 600 / 20：按钮文字、卡片标题
    static let bodyStrong = Style(size: 13, weight: .semibold, lineHeight: 20)
    /// 辅助 11 / 400 / 16：说明、时间、步骤状态（≈ `.subheadline`）
    static let caption = Style(size: 11, weight: .regular, lineHeight: 16)
    /// 辅助加粗 11 / 500 / 16：表头、标签文字、分组小标题
    static let captionStrong = Style(size: 11, weight: .medium, lineHeight: 16)
    /// 统计大数 24 / 600 / 28，数字等宽
    static let statNumber = Style(size: 24, weight: .semibold, lineHeight: 28, monospacedDigits: true)
}

extension View {
    /// 按规范的级别设字体和行高
    func textStyle(_ style: Typography.Style) -> some View {
        font(style.font).lineSpacing(style.lineSpacing)
    }
}

// MARK: - 间距

/// 规范第 3 节：只用 4 / 8 / 12 / 16 / 24 / 32 六档。
nonisolated enum Spacing {
    /// 4：图标和文字之间、标签内部、标题和说明之间
    static let xs: CGFloat = 4
    /// 8：并排按钮之间、列表项内边距、表单行上下、输入框左右内边距
    static let sm: CGFloat = 8
    /// 12：卡片标题和内容之间、表格列之间
    static let md: CGFloat = 12
    /// 16：卡片内边距、卡片之间
    static let lg: CGFloat = 16
    /// 24：页面四周边距、弹窗内边距、大区块之间
    static let xl: CGFloat = 24
    /// 32：较大的分组之间（少用）
    static let xxl: CGFloat = 32
}

/// 规范里的控件尺寸（不属于间距）。
nonisolated enum Metrics {
    static let buttonHeight: CGFloat = 28
    static let inputHeight: CGFloat = 28
    static let textAreaMinHeight: CGFloat = 72
    static let selectArrowSpace: CGFloat = 32
    static let segmentedHeight: CGFloat = 32
    static let tagHeight: CGFloat = 20
    static let toolbarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 220
    static let sidebarRowHeight: CGFloat = 32
    static let listRowHeight: CGFloat = 72
    static let formLabelWidth: CGFloat = 120
    static let menuItemHeight: CGFloat = 24
    static let icon: CGFloat = 16
    static let iconSmall: CGFloat = 12
    static let checkbox: CGFloat = 16
    static let checkboxRadius: CGFloat = 4
    static let switchSize = CGSize(width: 32, height: 20)
    static let dialogConfirmWidth: CGFloat = 420
    static let dialogNewWidth: CGFloat = 640
    static let dialogBatchWidth: CGFloat = 760
    static let thumbnailList = CGSize(width: 44, height: 60)
    static let thumbnailEditorList: CGFloat = 48
    static let editorImageWidth: CGFloat = 340
    static let gridShotHeight: CGFloat = 232
}

// MARK: - 圆角

/// 规范第 4 节。
nonisolated enum Radius {
    /// 6：标签、输入框、下拉框、小缩略图、菜单项、分段控件的选中块
    static let small: CGFloat = 6
    /// 10：按钮、分段控件、列表选中行、菜单、提示
    static let medium: CGFloat = 10
    /// 16：卡片、弹窗、网格卡片、编辑页大图、窗口
    static let large: CGFloat = 16

    static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

// MARK: - 阴影

/// 规范第 5 节。数值照 CSS 记（y 偏移、模糊半径），SwiftUI 的 shadow 半径取模糊的一半。
nonisolated enum Elevation: Sendable {
    /// 默认：卡片用 1px 分隔线描边，不用阴影
    case flat
    /// 悬停的网格卡片、弹窗、菜单、提示、多选操作条
    case raised

    struct Layer: Sendable {
        let color: Swatch.RGBA
        let y: CGFloat
        let blur: CGFloat
    }

    /// 浅色：0 1px 2px rgba(0,0,0,.06), 0 8px 24px rgba(0,0,0,.12)
    static let raisedLight = [Layer(color: .init(0x000000, alpha: 0.06), y: 1, blur: 2),
                              Layer(color: .init(0x000000, alpha: 0.12), y: 8, blur: 24)]
    /// 深色：0 0 0 1px rgba(255,255,255,.06), 0 8px 24px rgba(0,0,0,.45)
    static let raisedDarkRing = Swatch.RGBA(0xFFFFFF, alpha: 0.06)
    static let raisedDark = [Layer(color: .init(0x000000, alpha: 0.45), y: 8, blur: 24)]
}

private struct ElevationModifier<S: Shape>: ViewModifier {
    let elevation: Elevation
    let shape: S
    /// 0～1：阴影淡入淡出用
    var amount: Double = 1
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let layers = elevation == .flat ? [] : dark ? Elevation.raisedDark : Elevation.raisedLight
        let first = layers.first, second = layers.dropFirst().first
        content
            .overlay {
                if elevation == .raised, dark {
                    shape.stroke(Elevation.raisedDarkRing.color.opacity(amount), lineWidth: Palette.hairline)
                }
            }
            .shadow(color: (first?.color.color ?? .clear).opacity(amount), radius: (first?.blur ?? 0) / 2, y: first?.y ?? 0)
            .shadow(color: (second?.color.color ?? .clear).opacity(amount), radius: (second?.blur ?? 0) / 2, y: second?.y ?? 0)
    }
}

extension View {
    /// 规范的阴影档位；`amount` 在 0～1 之间时按比例淡化（悬停浮起用）
    func elevation(_ elevation: Elevation, in shape: some Shape = Radius.shape(Radius.large), amount: Double = 1) -> some View {
        modifier(ElevationModifier(elevation: elevation, shape: shape, amount: amount))
    }

    /// 卡片底：「卡片」色 + 1px 分隔线描边
    func surface(_ radius: CGFloat = Radius.large, fill: Swatch = Palette.card) -> some View {
        background(fill, in: Radius.shape(radius))
            .overlay(Radius.shape(radius).strokeBorder(Palette.divider, lineWidth: Palette.hairline))
    }

    /// 全软件统一的外观：主色固定为规范的蓝（不跟随系统强调色），按钮默认用次要按钮样式。
    /// 加在窗口最外层（弹窗也会继承）。
    func designSystem() -> some View {
        tint(Palette.primary.color).buttonStyle(.secondary)
    }
}
