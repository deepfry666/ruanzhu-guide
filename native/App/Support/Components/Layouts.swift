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

    private func columnWidths(_ total: CGFloat, _ count: Int) -> [CGFloat] {
        guard count > 1 else { return [total] }
        if let trailingWidth, count == 2 { return [max(0, total - spacing - trailingWidth), trailingWidth] }
        let width = max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
        return Array(repeating: width, count: count)
    }

    private func horizontal(_ width: CGFloat) -> Bool { width >= breakpoint }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? breakpoint
        if horizontal(width) {
            let widths = columnWidths(width, subviews.count)
            let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if horizontal(bounds.width) {
            var x = bounds.minX
            for (subview, width) in zip(subviews, columnWidths(bounds.width, subviews.count)) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
                y += height + spacing
            }
        }
    }
}
