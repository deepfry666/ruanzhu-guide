import SwiftUI

// MARK: 5 滑动选中块

/// 规范里的分段控件：高 32，内边距 4，填充底，圆角中；选中块圆角小 + 1px 分隔线描边，选中文字用正文加粗。
/// 切换时选中块的位置和宽度 0.4 秒弹性滑过去，文字颜色 0.2 秒匀速。
/// 减弱动态效果：选中块直接跳到新位置。
struct SegmentedTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var count: Int? = nil
    }

    @Binding var selection: Value
    let items: [Item]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                segment(items[index])
            }
        }
        .padding(Spacing.xs)
        .frame(height: Metrics.segmentedHeight)
        .background(Palette.fill, in: Radius.shape(Radius.medium))
    }

    private func segment(_ item: Item) -> some View {
        let selected = item.value == selection
        return Button {
            guard !selected else { return }
            if reduceMotion {
                selection = item.value
            } else {
                withAnimation(Motion.spring) { selection = item.value }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(item.title)
                    .font(selected ? Typography.bodyStrong.font : Typography.body.font)
                    .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                if let count = item.count {
                    Text("\(count)")
                        .font(Typography.body.number.font)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .animation(Motion.linear(0.2), value: selected)
            .lineLimit(1)
            .padding(.horizontal, Spacing.md)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    Radius.shape(Radius.small)
                        .fill(Palette.segmentThumb)
                        .overlay(Radius.shape(Radius.small).strokeBorder(Palette.divider, lineWidth: Palette.hairline))
                        .matchedGeometryEffect(id: "thumb", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
