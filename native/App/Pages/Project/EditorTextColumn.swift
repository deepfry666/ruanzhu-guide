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
                    Text(length >= floor ? "\(length) 字 ✓" : "\(length) / \(floor) 字").monospacedDigit().foregroundStyle(length >= floor ? Color.secondary : Color.orange)
                    if !data.readOnly {
                        historyMenu(id) { texts[id] = $0 }
                        Button("让大模型重写") { rewrite = ([id], "图\(index + 1)的说明") }.disabled(running)
                    }
                }
                TextEditor(text: Binding(get: { texts[id] ?? "" }, set: { texts[id] = $0 }))
                    .textStyle(Typography.body)
                    .lineSpacing(3)
                    .frame(minHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background(Palette.fill.color, in: RoundedRectangle(cornerRadius: Radius.small))
                    .disabled(!editable)
                if length < floor { warning("还差 \(floor - length) 字；不够 \(floor) 字时交付包生成不了") }
                if Rx.test(#"图\s*[0-9]"#, text) { warning("正文里不要写「图N」，图注会自动生成") }
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("图\(index + 1)").fontWeight(.semibold)
                    Text(screen.title).foregroundStyle(.secondary)
                }
                Text("截图检查通过后会自动写这一屏的说明。").foregroundStyle(.secondary)
            }
        }
    }

    /// 每一行下面：写要怎么改，直接改图或只改文字
    func changeBar(_ index: Int, _ screen: ScreenItem) -> some View {
        let id = screen.id
        let request = (changeRequests[id] ?? "").jsTrimmed
        let hasText = contentScreens.contains { $0["id"]?.string == id }
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text("要怎么改").foregroundStyle(.secondary)
                TextField("例如：底部按钮改成绿色、日期都改成内容日期、说明多写异常处理", text: Binding(get: { changeRequests[id] ?? "" }, set: { changeRequests[id] = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .disabled(!editable)
                Button("改图") { applyChange(index, screen, image: true) }
                    .buttonStyle(.primary)
                    .disabled(request.isEmpty || !editable || screen.file == nil)
                    .help("按这句话改这张截图（花一张图的费用），说明会按新图更新；改完会核对有没有改到")
                Button("只改文字") { applyChange(index, screen, image: false) }
                    .disabled(request.isEmpty || !editable || !hasText)
                    .help("只按这句话改这一屏的说明，不生图")
            }
            Text("改图会花一张图的费用，改完会核对有没有改到；只改文字不生图。现在的图和文字都会留在历史里。").textStyle(Typography.caption).foregroundStyle(.secondary)
        }
    }

    func applyChange(_ index: Int, _ screen: ScreenItem, image: Bool) {
        let instruction = (changeRequests[screen.id] ?? "").jsTrimmed
        guard !instruction.isEmpty else { return }
        Task {
            await autosave()
            let action: JSON = .obj([
                "type": .string(image ? "image" : "text"), "target": .string(screen.id), "targetLabel": .string("图\(index + 1)「\(screen.title)」"),
                "instruction": .string(instruction), "items": [],
            ])
            let ok = await model.perform(image ? "已开始改图，进度在页面上方" : "已开始改这一屏的说明") {
                _ = try await model.core?.pipeline.applyFeedback(data.dir, actions: [action])
            }
            if ok {
                changeRequests[screen.id] = ""
                onChanged()
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
                model.toast(.success, passed ? "已确认没有软件名\(remaining.isEmpty ? "" : "，还剩 \(remaining.count) 张")" : "已标记为不合格，可以重新生成或换回以前的截图")
            }
            onChanged()
        }
    }

}
