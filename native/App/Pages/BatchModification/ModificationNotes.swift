import StudioCore
import SwiftUI

struct FeedbackTarget: Hashable {
    let value: String
    let label: String
    static func options(_ data: ProjectData) -> [FeedbackTarget] {
        var options = [FeedbackTarget(value: "", label: "让软件判断")]
        options += data.screens.enumerated().map { FeedbackTarget(value: $0.element.id, label: "图\($0.offset + 1)「\($0.element.title)」") }
        options.append(FeedbackTarget(value: "all", label: "全部截图"))
        options.append(FeedbackTarget(value: "overview", label: "封面介绍"))
        if ProjectState(data.state).request?.wantDesign == true { options.append(FeedbackTarget(value: "design", label: "设计说明")) }
        return options
    }
    static func label(_ value: String?, in options: [FeedbackTarget]) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return options.first { $0.value == value }?.label ?? value
    }
}

struct ModificationNotes: View {
    let data: ProjectData
    let state: BatchModificationState
    @State private var showDone = false
    var body: some View {
        let pending = state.pending(data)
        let done = (ProjectState(data.state).feedback ?? []).filter { $0.status == "done" }
        SettingsGroup(title: "\(data.name) · 待处理 \(pending.count) 条") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if pending.isEmpty && done.isEmpty { Text("没有已保存的意见").foregroundStyle(Palette.textSecondary) }
                if data.plan == nil { Text("还没有界面规划，暂不能添加或整理意见。").foregroundStyle(Palette.textSecondary) }
                ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                    ModificationNoteRow(data: data, item: item, index: index, state: state)
                        .disabled(state.reason(data) != nil || state.force != "none")
                    Divider()
                }
                if !done.isEmpty {
                    DisclosureGroup("已处理 \(done.count) 条", isExpanded: $showDone) {
                        ForEach(done.reversed(), id: \.id) { item in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(item.text ?? "")
                                Text("\(formatTime(item.doneAt)) 已改：\(item.appliedAs ?? "")")
                                    .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
            }.padding(Spacing.lg)
        }
    }
}

private struct ModificationNoteRow: View {
    let data: ProjectData
    let item: FeedbackItem
    let index: Int
    let state: BatchModificationState
    var key: String { data.dir + "|" + (item.id ?? "") }
    var editing: Bool { state.editingNotes[key] != nil }
    var value: Binding<String> { Binding(get: { state.editingNotes[key] ?? "" }, set: { state.editingNotes[key] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if editing {
                TextField("修改意见", text: value, axis: .vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存") {
                        let text = value.wrappedValue
                        mutate(saved: true) { try await $0.pipeline.editFeedback(data.dir, item.id ?? "", text) }
                    }.disabled(value.wrappedValue.jsTrimmed.isEmpty)
                    Button("放弃编辑") { state.editingNotes[key] = nil }
                }
            } else {
                Text("\(index + 1). \(item.text ?? "")").textSelection(.enabled)
                FlowLayout(spacing: Spacing.sm) {
                    Menu(FeedbackTarget.label(item.target, in: FeedbackTarget.options(data)) ?? "让软件判断") {
                        ForEach(FeedbackTarget.options(data), id: \.self) { target in
                            Button(target.label) { mutate { try await $0.pipeline.setFeedbackTarget(data.dir, item.id ?? "", target.value.isEmpty ? nil : target.value) } }
                        }
                    }.fixedSize().help("改哪里")
                    Button("编辑") { state.editingNotes[key] = item.text ?? "" }.buttonStyle(.borderless)
                    Button("删除", role: .destructive) { mutate { try await $0.pipeline.removeFeedback(data.dir, item.id ?? "") } }.buttonStyle(.borderless)
                }
            }
        }
    }
    func mutate(saved: Bool = false, _ operation: @escaping (StudioCore) async throws -> Void) {
        guard !state.busy, let core = state.model.core else { return }
        state.busy = true
        Task {
            let success = await state.model.perform { try await operation(core) }
            if saved && success { state.editingNotes[key] = nil }
            state.model.bump(data.dir)
            await state.refresh()
            state.busy = false
        }
    }
}
