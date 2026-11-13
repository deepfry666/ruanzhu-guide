import SwiftUI

/// 自动换行的横排（标签列表用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 两栏布局：宽度够时左右排（trailingWidth 为 nil 时两栏等分），不够时上下排。
/// 打开修改意见侧栏后内容区会变窄，固定的 HStack 会把侧栏挤出窗口。
struct AdaptiveColumns: Layout {
    var breakpoint: CGFloat = 820
    var spacing: CGFloat = Spacing.xl
    var trailingWidth: CGFloat? = nil
    var leadingWidth: CGFloat? = nil

    struct Cache {
        var sizes: [CGFloat: [CGSize]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // 图片、文字或选择变化时重新测量；同一轮的尺寸探测和放置复用结果。
        cache.sizes.removeAll(keepingCapacity: true)
    }

    private func sizes(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if let sizes = cache.sizes[width] { return sizes }
        let widths = horizontal(width) ? columnWidths(width, subviews.count) : Array(repeating: width, count: subviews.count)
        let sizes = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)) }
        cache.sizes[width] = sizes
        return sizes
    }

    private func columnWidths(_ total: CGFloat, _ count: Int) -> [CGFloat] {
        guard count > 1 else { return [total] }
        if let leadingWidth, count == 2 { return [leadingWidth, max(0, total - spacing - leadingWidth)] }
        if let trailingWidth, count == 2 { return [max(0, total - spacing - trailingWidth), trailingWidth] }
        let width = max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
        return Array(repeating: width, count: count)
    }

    private func horizontal(_ width: CGFloat) -> Bool { width >= breakpoint }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // 固定导航栏给出真实最小宽度，不把零宽或无限宽探测传给文字控件。
        let minimum = leadingWidth ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? max($0, minimum) : nil } ?? breakpoint
        let heights = sizes(width: width, subviews: subviews, cache: &cache).map(\.height)
        let height = horizontal(width) ? heights.max() ?? 0 : heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = sizes(width: bounds.width, subviews: subviews, cache: &cache)
        if horizontal(bounds.width) {
            var x = bounds.minX
            for (subview, width) in zip(subviews, columnWidths(bounds.width, subviews.count)) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for (subview, size) in zip(subviews, sizes) {
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
                y += size.height + spacing
            }
        }
    }
}
