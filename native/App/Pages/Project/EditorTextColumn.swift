import StudioCore
import SwiftUI

extension EditorTab {
    @ViewBuilder
    func textColumn(_ index: Int, _ screen: ScreenItem) -> some View {
        let id = screen.id
        if contentScreens.contains(where: { $0["id"]?.string == id }) {
            let text = texts[id] ?? ""
            let length = text.jsTrimmed.jsLength
            let edited = data.state["screens"]?[id]?["textEdited"].isTruthy ?? false
            VStack(alignment: .leading, spacing: Spacing.sm) {
                FlowLayout(spacing: Spacing.sm) {
                    Text("图\(index + 1)").fontWeight(.semibold)
                    TextField("界面标题（也是图注）", text: Binding(get: { titles[id] ?? "" }, set: { titles[id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .disabled(!editable)
                    if edited { TagView(text: "人工改过", tone: .purple) }
                    Text(length >= floor ? "\(length) 字 ✓" : "\(length) / \(floor) 字").monospacedDigit().foregroundStyle(length >= floor ? Palette.textSecondary : Palette.warning)
                    if !data.readOnly {
                        historyMenu(id) { texts[id] = $0 }
                    }
                }
                TextEditor(text: Binding(get: { texts[id] ?? "" }, set: { texts[id] = $0 }))
                    .textStyle(Typography.body)
                    .lineSpacing(3)
                    .frame(minHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background(Palette.fill, in: Radius.shape(Radius.small))
                    .disabled(!editable)
                if length < floor { warning("还差 \(floor - length) 字；不够 \(floor) 字时交付包生成不了") }
                if Rx.test(#"图\s*[0-9]"#, text) { warning("正文里不要写「图N」，图注会自动生成") }
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("图\(index + 1)").fontWeight(.semibold)
                    Text(screen.title).foregroundStyle(Palette.textSecondary)
                }
                Text("截图检查通过后会自动写这一屏的说明。").foregroundStyle(Palette.textSecondary)
            }
        }
    }

    func manual(_ screen: ScreenItem, _ passed: Bool) {
        Task {
            guard await model.perform(nil, { try await model.core?.pipeline.manualGate(data.dir, screen.id, passed) }) else { return }
            let remaining = data.screens.filter { $0.id != screen.id && !["passed", "manual-passed"].contains($0.gate?["status"]?.string ?? "") }
            if passed && remaining.isEmpty {
                model.toast(.success, "全部截图已确认，继续生成文案和交付包")
                model.core?.run(data.dir)
            } else {
                model.toast(.success, passed ? "已确认没有软件名\(remaining.isEmpty ? "" : "，还剩 \(remaining.count) 张")" : "已标记为不合格，可以通过「修改」重做或换回以前的截图")
            }
            onChanged()
        }
    }

}
