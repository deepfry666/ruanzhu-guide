import StudioCore
import SwiftUI

struct BatchModificationPreview: View {
    @Bindable var state: BatchModificationState
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("取消勾选即可排除某个动作；一条意见只执行部分动作时，原意见仍会保留供继续处理。").foregroundStyle(Palette.textSecondary)
            ForEach($state.previews) { $preview in
                ModificationProjectPreview(preview: $preview)
            }
            if state.previews.isEmpty, state.force == "none", state.codeMode == "none" {
                Banner(.info, "没有可执行的修改", message: "意见会保留，可以返回修改或稍后再处理。")
            }
            BatchModificationSummary(state: state)
        }
    }
}

private struct ModificationProjectPreview: View {
    @Binding var preview: ModificationPreview
    var body: some View {
        SettingsGroup(title: preview.data.name) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let error = preview.error { Banner(.warning, "整理未完成", message: error) }
                else {
                    if let notice = preview.originalPlan["notice"]?.string, !notice.isEmpty { Banner(.warning, notice) }
                    if let summary = preview.originalPlan["summary"]?.string { Text(summary) }
                    if !preview.actions.isEmpty {
                        Toggle("选择全部动作", isOn: Binding(get: { preview.checked.allSatisfy { $0 } }, set: { preview.checked = Array(repeating: $0, count: preview.actions.count) }))
                            .toggleStyle(.checkbox)
                    }
                    ForEach(preview.actions.indices, id: \.self) { index in
                        ModificationActionRow(action: $preview.actions[index], included: $preview.checked[index], pending: pending)
                    }
                    ForEach(preview.questions.indices, id: \.self) { index in question(index) }
                    if preview.actions.isEmpty && preview.questions.isEmpty { Text("没有可直接执行的动作，意见仍留在清单中。").foregroundStyle(Palette.textSecondary) }
                }
            }.padding(Spacing.lg)
        }
    }
    var pending: [FeedbackItem] { preview.data.pendingFeedbackItems }
    func sources(_ question: JSON) -> [FeedbackItem] { pending.filter { item in question["items"].items.contains { $0.string == item.id } } }
    func question(_ index: Int) -> some View {
        let item = preview.questions[index]
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            TagView(text: "待指定位置", tone: .orange)
            Text(item["question"].text)
            ForEach(sources(item), id: \.id) { Text($0.text ?? "").foregroundStyle(Palette.textSecondary) }
            Picker("改哪里", selection: $preview.questionTargets[index]) {
                Text("请选择").tag("")
                ForEach(FeedbackTarget.options(preview.data).filter { !$0.value.isEmpty }, id: \.self) { Text($0.label).tag($0.value) }
            }
            Button("按原话改这里") { resolve(index) }.disabled(preview.questionTargets[index].isEmpty)
            Text("不处理会留在项目的待处理意见中。").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
        }.padding(Spacing.md).surface()
    }
    func resolve(_ index: Int) {
        let target = preview.questionTargets[index], question = preview.questions[index]
        let type = ["overview", "design"].contains(target) ? target : "image"
        preview.actions.append(.obj([
            "key": .string(UUID().uuidString), "type": .string(type), "target": .string(target),
            "targetLabel": .string(FeedbackTarget.label(target, in: FeedbackTarget.options(preview.data)) ?? target),
            "instruction": .string(sources(question).compactMap(\.text).joined(separator: "；")), "items": question["items"] ?? []
        ]))
        preview.checked.append(true)
        preview.questions.remove(at: index)
        preview.questionTargets.remove(at: index)
    }
}

private struct ModificationActionRow: View {
    @Binding var action: JSON
    @Binding var included: Bool
    let pending: [FeedbackItem]
    var type: String { action["type"].text }
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Toggle("执行这项修改", isOn: $included).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: Spacing.sm) {
                FlowLayout(spacing: Spacing.sm) {
                    if ["image", "text"].contains(type), action["target"].text != "all" {
                        SegmentedTabs(
                            selection: Binding(get: { type }, set: { action["type"] = .string($0) }),
                            items: [
                                .init(value: "image", title: "改图"),
                                .init(value: "text", title: "只改文字"),
                            ]
                        )
                        .fixedSize()
                    } else { TagView(text: ["image": "改图", "text": "改文字", "data": "改数据", "overview": "改封面介绍", "design": "改设计说明", "replan": "重新规划"][type] ?? type) }
                    Text(action["targetLabel"].text).textStyle(Typography.bodyStrong)
                }
                TextField("修改指令", text: Binding(get: { action["instruction"].text }, set: { action["instruction"] = .string($0) }), axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder)
                Text("来自：" + pending.enumerated().filter { pair in action["items"].items.contains { $0.string == pair.element.id } }.map { "第\($0.offset + 1)条" }.joined(separator: "、"))
                    .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            }.disabled(!included)
        }.padding(Spacing.md).surface()
    }
}

struct BatchModificationSummary: View {
    let state: BatchModificationState
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !state.codeDirs.isEmpty { Text("代码材料：\(state.codeDirs.count) 个项目（不调用 AI）") }
            if state.force == "rewrite" { Text("只重写文字：\(state.editable.count) 个项目，包含人工改过的说明；不生成图片。") }
            else if state.force == "regenerate" { Text("从头重做：\(state.editable.count) 个项目。旧规划、截图和文字先归档，重新规划、生图和写说明；代码来源保持原样。") }
            else {
                Text("按意见修改：\(state.chosen.count) 个项目，\(state.chosen.reduce(0) { $0 + $1.chosen.count }) 个动作。")
                if state.chosen.flatMap(\.chosen).contains(where: { $0["type"].text == "replan" }) { Text("包含重新规划：相关项目的截图和说明会重做。").foregroundStyle(Palette.warning) }
            }
            if state.force != "none" || !state.chosen.isEmpty {
                Text("修改会调用收费模型；改图、改数据或重新规划也可能产生图片费用。任务进入批量队列后可以暂停、继续。").foregroundStyle(Palette.warning)
            }
        }.padding(Spacing.lg).surface()
    }
}

struct BatchModificationConfirmation: View {
    let state: BatchModificationState
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("确认以下处理范围和费用后执行。未勾选的动作不会加入本次队列。")
            BatchModificationSummary(state: state)
            Text("代码处理先完成，然后把模型任务加入队列。交付包会自动更新，无需手动重新导出 PDF。")
                .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            ForEach(state.chosen) { preview in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(preview.data.name).textStyle(Typography.bodyStrong)
                    ForEach(Array(preview.chosen.enumerated()), id: \.offset) { _, action in
                        Text("\(action["targetLabel"].text)：\(action["instruction"].text)")
                    }
                }.padding(Spacing.lg).surface()
            }
        }
    }
}
