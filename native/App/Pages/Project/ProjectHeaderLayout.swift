import SwiftUI

/// 状态、页面标签、操作各保留一份；窄窗口把标签移到下一行，不压缩标签文字。
struct ProjectHeaderLayout: Layout {
    private let spacing = Spacing.md

    struct Cache {
        var ideal: [CGSize]
        var constrained: [CGFloat: [CGSize]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func positions(width: CGFloat, sizes: [CGSize]) -> (height: CGFloat, points: [CGPoint]) {
        guard sizes.count == 3 else { return (0, []) }
        let status = sizes[0], tabs = sizes[1], actions = sizes[2]
        let total = status.width + tabs.width + actions.width + spacing * 2
        if total <= width {
            let height = sizes.map(\.height).max() ?? 0
            let centerX = min(max((width - tabs.width) / 2, status.width + spacing), width - actions.width - spacing - tabs.width)
            return (height, [CGPoint(x: 0, y: (height - status.height) / 2),
                             CGPoint(x: centerX, y: (height - tabs.height) / 2),
                             CGPoint(x: width - actions.width, y: (height - actions.height) / 2)])
        }
        if status.width + actions.width + spacing <= width {
            let firstHeight = max(status.height, actions.height)
            return (firstHeight + spacing + tabs.height,
                    [CGPoint(x: 0, y: (firstHeight - status.height) / 2),
                     CGPoint(x: max(0, (width - tabs.width) / 2), y: firstHeight + spacing),
                     CGPoint(x: width - actions.width, y: (firstHeight - actions.height) / 2)])
        }
        return (status.height + tabs.height + actions.height + spacing * 2,
                [.zero, CGPoint(x: 0, y: status.height + spacing),
                 CGPoint(x: 0, y: status.height + tabs.height + spacing * 2)])
    }

    /// 动作区在极窄内容区内继续换行，不把整个头部撑到窗口外。
    private func sizes(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if let sizes = cache.constrained[width] { return sizes }
        let sizes = zip(subviews, cache.ideal).map { subview, ideal in
            ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
        cache.constrained[width] = sizes
        return sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ideal = cache.ideal.map(\.width).reduce(0, +) + spacing * 2
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? ideal
        return CGSize(width: width, height: positions(width: width, sizes: sizes(width: width, subviews: subviews, cache: &cache)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = sizes(width: bounds.width, subviews: subviews, cache: &cache)
        let layout = positions(width: bounds.width, sizes: sizes)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: ProposedViewSize(sizes[index]))
        }
    }
}
