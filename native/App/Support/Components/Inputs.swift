import StudioCore
import SwiftUI

/// 多个词的输入框（回车添加，点 × 删除）。
struct TokenEditor: View {
    @Binding var tokens: [String]
    var placeholder = "输入后回车"
    var suggestions: [String] = []
    var onCommit: (() -> Void)? = nil
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !tokens.isEmpty {
                FlowLayout {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: Spacing.xs) {
                            Text(token).textStyle(Typography.body)
                            Button {
                                tokens.removeAll { $0 == token }
                                onCommit?()
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: Metrics.iconSmall))
                            }
                            .buttonStyle(.iconAction)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .frame(minHeight: Metrics.tagHeight)
                        .background(Palette.fill, in: Radius.shape(Radius.small))
                    }
                }
            }
            HStack(spacing: Spacing.sm) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if !suggestions.filter({ !tokens.contains($0) }).isEmpty {
                    Menu {
                        ForEach(suggestions.filter { !tokens.contains($0) }, id: \.self) { item in
                            Button(item) {
                                tokens.append(item)
                                onCommit?()
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
        }
    }

    private func add() {
        let value = draft.jsTrimmed
        draft = ""
        guard !value.isEmpty, !tokens.contains(value) else { return }
        tokens.append(value)
        onCommit?()
    }
}

/// 文本输入框：失去焦点或回车时保存（系统设置没有「保存」按钮）。
struct CommitTextField: View {
    let placeholder: String
    let value: String
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .textFieldStyle(.roundedBorder)
            .lineLimit(axis == .vertical ? 1...5 : 1...1)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, next in if !focused { draft = next } }
            .onSubmit { if draft != value { onCommit(draft) } }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != value { onCommit(draft) }
            }
    }
}

/// 整数输入（带后缀单位）。
struct NumberField: View {
    let value: Int
    var range: ClosedRange<Int> = 0...1000
    var suffix: String? = nil
    var width: CGFloat = 64
    let onCommit: (Int) -> Void
    @State private var draft = 0

    var body: some View {
        HStack(spacing: Spacing.xs) {
            TextField("", value: $draft, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onSubmit(commit)
            Stepper("", value: $draft, in: range)
                .labelsHidden()
                .onChange(of: draft) { _, _ in commit() }
            if let suffix { Text(suffix).foregroundStyle(Palette.textSecondary) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in draft = next }
    }

    private func commit() {
        let clamped = min(range.upperBound, max(range.lowerBound, draft))
        if clamped != draft { draft = clamped }
        if clamped != value { onCommit(clamped) }
    }
}

/// 小数输入（秒数等）。
struct DecimalField: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1000
    var suffix: String? = nil
    let onCommit: (Double) -> Void
    @State private var draft = 0.0

    var body: some View {
        HStack(spacing: Spacing.xs) {
            TextField("", value: $draft, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onSubmit(commit)
            if let suffix { Text(suffix).foregroundStyle(Palette.textSecondary) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in draft = next }
    }

    private func commit() {
        let clamped = min(range.upperBound, max(range.lowerBound, draft))
        draft = clamped
        if clamped != value { onCommit(clamped) }
    }
}

/// 并发数快速选择：常用档位 + 当前值 + 「不限」（存成 0）。
struct ConcurrencyPicker: View {
    let value: Int
    let presets: [Int]
    let unit: String
    let onChange: (Int) -> Void

    var body: some View {
        let options = Array(Set(presets + (value > 0 ? [value] : []))).sorted()
        Picker("", selection: Binding(get: { max(0, value) }, set: { onChange($0) })) {
            ForEach(options, id: \.self) { Text("\($0) \(unit)").tag($0) }
            Divider()
            Text("不限").tag(0)
        }
        .labelsHidden()
        .fixedSize()
    }
}

let PROJECT_CONCURRENCY_PRESETS = [1, 2, 3, 4, 5, 6, 8, 10]
let IMAGE_CONCURRENCY_PRESETS = [2, 4, 6, 8, 10, 15, 20, 30, 50]

/// 「每次同时处理 N 个」这类文字；0 表示不限。
func concurrencyText(_ value: Int, _ unit: String = "个") -> String { value <= 0 ? "不限" : "\(value) \(unit)" }
