import SwiftUI

// 动画对照表（规范第 7 节）。每种动画只用在对照表写明的场景；每个实现都读取系统的
// 「减弱动态效果」（accessibilityReduceMotion），开启后按对照表最后一列退化。
//
//  1 弹性按压   pressEffect(_:)          本文件
//  2 按钮变形   MorphButton              MotionMorph.swift
//  3 勾选描线   CheckBadge / DrawnCheck   MotionCheck.swift
//  4 点击绽放   bloom(trigger:)          MotionCheck.swift
//  5 滑动选中块 SegmentedTabs            MotionSegmented.swift
//  6 弹出提示   ToastMotion              本文件（Toast.swift 使用）
//  7 依次入场   staggeredEntrance(...)   本文件
//  8 骨架闪光   Skeleton                 本文件
//  9 摇头       shake(trigger:)          本文件
// 10 数字滚动   numberRoll(_:)           本文件
// 11 悬停浮起   hoverLift()              本文件

/// 曲线和通用时长。
nonisolated enum Motion {
    /// 弹性（带一点回弹）：cubic-bezier(.34, 1.56, .64, 1)
    static let spring = Animation.spring(duration: 0.4, bounce: 0.3)
    static func spring(_ duration: Double) -> Animation { .spring(duration: duration, bounce: 0.3) }
    /// 减速（进入）：cubic-bezier(.22, 1, .36, 1)
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: duration) }
    /// 加速（退出）：cubic-bezier(.4, 0, 1, 1)
    static func easeIn(_ duration: Double) -> Animation { .timingCurve(0.4, 0, 1, 1, duration: duration) }
    /// 匀速
    static func linear(_ duration: Double) -> Animation { .linear(duration: duration) }
    /// 表外的界面变化、以及「减弱动态效果」时的退化：0.2 秒匀速淡入淡出
    static let fade = Animation.linear(duration: 0.2)

    /// 关键帧里用的同款曲线
    static let easeOutCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.22, y: 1), endControlPoint: UnitPoint(x: 0.36, y: 1))
    static let springCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.34, y: 1.56), endControlPoint: UnitPoint(x: 0.64, y: 1))
}

// MARK: 1 弹性按压

private struct PressEffect: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // 按下 0.1 秒减速缩到 0.94；松手 0.4 秒弹性回到原大小
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            // 减弱动态效果：不缩放，按下时变为 70% 不透明度（0.1 秒）
            .opacity(pressed && reduceMotion ? 0.7 : 1)
            .animation(reduceMotion ? Motion.linear(0.1) : pressed ? Motion.easeOut(0.1) : Motion.spring, value: pressed)
    }
}

extension View {
    /// 所有按钮按下时的弹性按压（按钮样式里已经带了，自绘的可点区域才需要单独加）
    func pressEffect(_ pressed: Bool) -> some View { modifier(PressEffect(pressed: pressed)) }
}

// MARK: 6 弹出提示

/// 提示的进出场和停留时间。
nonisolated enum ToastMotion {
    /// 停留：成功和信息 2.5 秒，失败 5 秒
    static let shortDwell: Double = 2.5
    static let longDwell: Double = 5

    /// 进入：从下方 24、0.9 倍处 0.45 秒弹性弹到原位，不透明度 0.2 秒；
    /// 退出：0.25 秒加速下移 12 并淡出。减弱动态效果：只淡入、淡出，各 0.2 秒。
    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return AnyTransition.opacity.animation(Motion.fade) }
        let insertion = AnyTransition.offset(y: 24).combined(with: .scale(scale: 0.9)).animation(Motion.spring(0.45))
            .combined(with: AnyTransition.opacity.animation(Motion.linear(0.2)))
        let removal = AnyTransition.offset(y: 12).combined(with: .opacity).animation(Motion.easeIn(0.25))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

// MARK: 7 依次入场

enum EntranceMode {
    /// 列表第一次出现：从下方 8 上浮并淡入，0.4 秒减速，相邻两行间隔 0.04 秒
    case stagger
    /// 切换分组：不重播，只淡入 0.2 秒
    case fade
    /// 不做动画（例如滚动时重新出现的行）
    case none
}

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    let mode: EntranceMode
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = shown || mode == .none
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion || mode != .stagger ? 0 : 8)
            .onAppear {
                guard !shown, mode != .none else { return }
                // 只有前 12 行有间隔，之后的和第 12 行一起出现；减弱动态效果：整个列表一起淡入 0.2 秒
                let animation = reduceMotion || mode == .fade
                    ? Motion.fade
                    : Motion.easeOut(0.4).delay(Double(min(index, 11)) * 0.04)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// 列表行的依次入场；`index` 是行号（从 0 开始）
    func staggeredEntrance(index: Int, mode: EntranceMode = .stagger) -> some View {
        modifier(StaggeredEntrance(index: index, mode: mode))
    }
}

// MARK: 8 骨架闪光

/// 缩略图加载中的占位：填充色上一道高光从右扫到左，1.4 秒一轮匀速循环。
/// 减弱动态效果：静止的填充色占位。加载完成后截图 0.2 秒淡入（由使用方用 `Motion.fade`）。
struct Skeleton: View {
    /// nil：直角（外面已经按截图圆角裁切时用）
    var cornerRadius: CGFloat? = Radius.small
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 1.4

    var body: some View {
        let shape = Radius.shape(cornerRadius ?? 0)
        if reduceMotion {
            shape.fill(Palette.fill)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                // 高光中心从右边外侧（1.5 倍宽）匀速移到左边外侧（-0.5 倍宽）；渐变总宽 3 倍
                let center = 1.5 - 2 * phase
                let fill = Palette.fill.color, highlight = Palette.skeletonHighlight.color
                shape.fill(LinearGradient(
                    stops: [.init(color: fill, location: 0), .init(color: fill, location: 0.3), .init(color: highlight, location: 0.5),
                            .init(color: fill, location: 0.7), .init(color: fill, location: 1)],
                    startPoint: UnitPoint(x: center - 1.5, y: 0.5), endPoint: UnitPoint(x: center + 1.5, y: 0.5)))
            }
        }
    }
}

// MARK: 9 摇头

private struct ShakeEffect: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 左右各晃两次（±6），共 0.4 秒，每段减速；减弱动态效果：不晃（边框和原因由使用方显示）
        let reduceMotion = reduceMotion
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
            view.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.08, timingCurve: Motion.easeOutCurve)
                LinearKeyframe(6, duration: 0.08, timingCurve: Motion.easeOutCurve)
                LinearKeyframe(-6, duration: 0.08, timingCurve: Motion.easeOutCurve)
                LinearKeyframe(6, duration: 0.08, timingCurve: Motion.easeOutCurve)
                LinearKeyframe(0, duration: 0.08, timingCurve: Motion.easeOutCurve)
            }
        }
    }
}

extension View {
    /// 表单填错时摇头；`trigger` 每加一次晃一次
    func shake(trigger: Int) -> some View { modifier(ShakeEffect(trigger: trigger)) }
}

// MARK: 10 数字滚动

private struct NumberRoll<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 每一位像里程表一样滚到新值，0.5 秒减速；减弱动态效果：数字直接换
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : Motion.easeOut(0.5), value: value)
    }
}

extension View {
    /// 统计数字变化时滚动到新值
    func numberRoll(_ value: some Equatable) -> some View { modifier(NumberRoll(value: value)) }
}

// MARK: 11 悬停浮起

private struct HoverLift: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lifted = hovering && !reduceMotion
        content
            // 阴影从「无」变为「浮起」；减弱动态效果：只有阴影 0.2 秒淡入
            .elevation(.raised, in: Radius.shape(cornerRadius), amount: hovering ? 1 : 0)
            // 0.25 秒减速：上移 4、放大到 1.02
            .scaleEffect(lifted ? 1.02 : 1)
            .offset(y: lifted ? -4 : 0)
            .animation(reduceMotion ? Motion.fade : Motion.easeOut(0.25), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 网格视图卡片的悬停浮起
    func hoverLift(cornerRadius: CGFloat = Radius.large) -> some View { modifier(HoverLift(cornerRadius: cornerRadius)) }
}
