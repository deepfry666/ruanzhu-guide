import StudioCore
import SwiftUI

enum ScreenChangeScope: String, CaseIterable, Identifiable {
    case image, text
    var id: String { rawValue }
    var title: String { self == .image ? "图和文字" : "只改文字" }
}

/// 确认时使用点击时的屏幕、范围和意见，不随之后的选中项改变。
struct ScreenChangeRequest {
    let screenID: String
    let label: String
    let instruction: String
    let scope: ScreenChangeScope

    var confirmation: String {
        let action = instruction.isEmpty ? "按原要求重做" : "按填写的要求修改"
        if scope == .image {
            return "将\(action)\(label)的截图，并按新图更新模型生成的说明；人工改过的文字保留，需要核对是否仍与新图一致。会产生一张图的费用，文字处理及检查也可能计费。旧图和文字会保留在历史中。"
        }
        return "将\(action)\(label)的说明，包括人工改过的文字；不会生成图片。会调用文字模型，旧文字会保留在历史中。"
    }
}

extension EditorTab {
    func changeBar(_ index: Int, _ screen: ScreenItem) -> some View {
        let scope = changeScopes[screen.id] ?? .image
        let instruction = (changeRequests[screen.id] ?? "").jsTrimmed
        let unavailable = scope == .text ? texts[screen.id] == nil : !instruction.isEmpty && screen.file == nil
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("修改这一屏").textStyle(Typography.bodyStrong)
            TextField("要怎么改（留空按原要求重做）", text: Binding(get: { changeRequests[screen.id] ?? "" }, set: { changeRequests[screen.id] = $0 }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(!editable)
            FlowLayout(spacing: Spacing.sm) {
                Picker("修改范围", selection: Binding(get: { changeScopes[screen.id] ?? .image }, set: { changeScopes[screen.id] = $0 })) {
                    ForEach(ScreenChangeScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!editable)
                Button(submittingChange ? "正在提交…" : "修改") {
                    let change = ScreenChangeRequest(screenID: screen.id, label: "图\(index + 1)「\(screen.title)」", instruction: instruction, scope: scope)
                    if scope == .image || instruction.isEmpty { pendingChange = change }
                    else { submitChange(change) }
                }
                .buttonStyle(.primary)
                .disabled(!editable || unavailable)
            }
            Text(unavailable ? (scope == .text ? "这一屏还没有说明，请先完成内容生成。" : "这一屏还没有截图；留空可按原要求生成。") : "留空按原要求重做；填写要求后按要求修改。图和文字会产生图片费用，执行前需要确认；人工改过的文字保留，需核对。只改文字不生图。")
                .textStyle(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    func submitChange(_ change: ScreenChangeRequest) {
        pendingChange = nil
        guard editable, data.screens.contains(where: { $0.id == change.screenID }), let core = model.core else { return }
        submittingChange = true
        Task {
            defer { submittingChange = false }
            guard await autosave() else {
                model.toast(.error, "文字尚未保存，未开始修改。请先解决保存问题后重试。")
                return
            }
            let ok = await model.perform("已开始修改，进度在页面上方") {
                if change.instruction.isEmpty {
                    if change.scope == .image {
                        _ = try core.pipeline.regenerateScreen(data.dir, change.screenID)
                    } else {
                        _ = try await core.pipeline.rewriteContent(data.dir, [change.screenID])
                    }
                } else {
                    let action: JSON = .obj([
                        "type": .string(change.scope.rawValue), "target": .string(change.screenID),
                        "targetLabel": .string(change.label), "instruction": .string(change.instruction), "items": [],
                    ])
                    _ = try await core.pipeline.applyFeedback(data.dir, actions: [action])
                }
            }
            if ok {
                if (changeRequests[change.screenID] ?? "").jsTrimmed == change.instruction { changeRequests[change.screenID] = "" }
                onChanged()
            }
        }
    }
}
