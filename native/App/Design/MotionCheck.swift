import SwiftUI

// MARK: 3 勾选描线

/// 对勾的一笔（24 × 24 网格里 5,12.5 → 9.5,17 → 19,7.5），配合 `trim` 描出来。
nonisolated struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: point(5, 12.5))
        path.addLine(to: point(9.5, 17))
        path.addLine(to: point(19, 7.5))
        return path
    }
}

/// 描出来的对勾（按钮变形完成时用）：0.35 秒减速一笔画出，晚 0.1 秒开始。
/// 减弱动态效果：直接显示。
struct DrawnCheck: View {
    var size: CGFloat = Metrics.icon
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CheckStroke()
            .trim(from: 0, to: reduceMotion ? 1 : progress)
            .stroke(.foreground, style: StrokeStyle(lineWidth: size / 10, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.easeOut(0.35).delay(0.1)) { progress = 1 }
            }
    }
}

/// 步骤完成、导出成功的圆形对勾。变成完成时：圆 0.25 秒减速变成功色，同时 0.4 秒弹性 1 → 1.08 → 1；
/// 对勾 0.35 秒减速一笔画出，晚 0.1 秒开始。一出现就是完成状态的不播动画。
/// 减弱动态效果：圆直接变色，对勾 0.2 秒淡入。
struct CheckBadge: View {
    let checked: Bool
    var size: CGFloat = Spacing.xl
    @State private var drawn: CGFloat = 0
    @State private var pops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(checked ? AnyShapeStyle(Palette.success) : AnyShapeStyle(.clear))
            Circle().strokeBorder(checked ? Palette.success : Palette.divider, lineWidth: 1.5)
            CheckStroke()
                .trim(from: 0, to: reduceMotion ? 1 : drawn)
                .stroke(Palette.onColor, style: StrokeStyle(lineWidth: size / 10, lineCap: .round, lineJoin: .round))
                .frame(width: size * 14 / 24, height: size * 14 / 24)
                .opacity(reduceMotion ? drawn : 1)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Motion.easeOut(0.25), value: checked)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: pops) { view, scale in
            view.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(1.08, duration: 0.2, timingCurve: Motion.springCurve)
                LinearKeyframe(1, duration: 0.2, timingCurve: Motion.springCurve)
            }
        }
        .onAppear { drawn = checked ? 1 : 0 }
        .onChange(of: checked) { _, isChecked in
            guard isChecked else {
                drawn = 0
                return
            }
            if reduceMotion {
                withAnimation(Motion.fade) { drawn = 1 }
            } else {
                pops += 1
                withAnimation(Motion.easeOut(0.35).delay(0.1)) { drawn = 1 }
            }
        }
    }
}

// MARK: 4 点击绽放

/// 只用在「整个项目生成完成」：12 个 6 的小圆点（主色、成功、信息、警告轮流）从中心向外飞出并缩小消失，
/// 0.5 秒减速；同时一圈 2 宽的成功色光环从 0.6 倍放大到 1.7 倍并淡出。每个项目只播一次（由使用方决定何时改 trigger）。
/// 减弱动态效果：不播。
private struct BloomEffect<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @State private var playing = false
    @State private var progress: CGFloat = 0
    @State private var distances: [CGFloat] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var colors: [Swatch] { [Palette.primary, Palette.success, Palette.info, Palette.warning] }
    private static var dot: CGFloat { 6 }

    func body(content: Content) -> some View {
        content
            .overlay {
                if playing {
                    GeometryReader { geometry in
                        let size = max(geometry.size.width, geometry.size.height)
                        ZStack {
                            Circle()
                                .stroke(Palette.success, lineWidth: 2)
                                .frame(width: size, height: size)
                                .scaleEffect(0.6 + 1.1 * progress)
                                .opacity(1 - progress)
                            ForEach(distances.indices, id: \.self) { index in
                                let angle = Double(index) / Double(distances.count) * 2 * .pi
                                let distance = (size / 2 + distances[index]) * progress
                                Circle()
                                    .fill(Self.colors[index % Self.colors.count])
                                    .frame(width: Self.dot, height: Self.dot)
                                    .scaleEffect(1 - progress)
                                    .opacity(1 - progress)
                                    .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                distances = (0..<12).map { _ in 18 + CGFloat.random(in: 0...14) }
                progress = 0
                playing = true
                // 先让粒子出现在起点，下一帧再开始飞出
                DispatchQueue.main.async {
                    withAnimation(Motion.easeOut(0.5)) {
                        progress = 1
                    } completion: {
                        playing = false
                    }
                }
            }
    }
}

extension View {
    /// 整个项目生成完成时的绽放；`trigger` 变化时播一次
    func bloom(trigger: some Equatable) -> some View { modifier(BloomEffect(trigger: trigger)) }
}
