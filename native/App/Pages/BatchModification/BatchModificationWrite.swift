import StudioCore
import SwiftUI

struct BatchModificationWrite: View {
    @Bindable var state: BatchModificationState
    @State private var pasted = ""
    @State private var showNames = false
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsGroup(title: "项目范围（\(state.dirs.count)）") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(state.dirs, id: \.self) { dir in
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(state.projects[dir]?.name ?? state.model.projects.first { $0.dir == dir }?.name ?? "无法读取项目")
                                if let data = state.projects[dir], let reason = state.reason(data) {
                                    Text("跳过：\(reason)").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                                } else if let error = state.errors[dir] {
                                    Text(error).textStyle(Typography.caption).foregroundStyle(Palette.danger)
                                }
                            }
                            Spacer()
                            Button("移除") { state.dirs.removeAll { $0 == dir }; state.target = "" }.buttonStyle(.borderless).disabled(!state.editingNotes.isEmpty)
                        }
                    }
                    if state.dirs.isEmpty { Text("从列表多选项目，或粘贴软件名名单添加。 ").foregroundStyle(Palette.textSecondary) }
                    DisclosureGroup("粘贴名单增删项目", isExpanded: $showNames) {
                        TextField("每行一个软件名", text: $pasted, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("按名单添加") { changeNames(false) }.disabled(pasted.jsTrimmed.isEmpty || !state.editingNotes.isEmpty)
                            Button("按名单移除") { changeNames(true) }.disabled(pasted.jsTrimmed.isEmpty || !state.editingNotes.isEmpty)
                        }
                        if !state.missing.isEmpty { Text("未唯一匹配：" + state.missing.joined(separator: "、")).foregroundStyle(Palette.warning) }
                    }
                }.padding(Spacing.lg)
            }
            SettingsGroup(title: "修改意见", footer: "加入清单会保存到当前可修改的项目；可连续添加多条。取消窗口后仍可从项目概览继续处理。") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if state.dirs.count == 1, let data = state.projects[state.dirs[0]] {
                        Picker("改哪里", selection: $state.target) {
                            ForEach(FeedbackTarget.options(data), id: \.self) { Text($0.label).tag($0.value) }
                        }
                    } else { Text("新意见添加到范围内的所有可修改项目；位置由软件分别判断。").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary) }
                    TextField("写下要修改的内容", text: $state.note, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button("加入清单") { Task { await state.addNote() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(state.note.jsTrimmed.isEmpty || !state.editable.contains { $0.plan != nil })
                    if !state.note.jsTrimmed.isEmpty { Text("先加入清单，再进入预览。").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary) }
                }.padding(Spacing.lg).disabled(state.force != "none")
            }
            ForEach(state.dirs, id: \.self) { dir in
                if let data = state.projects[dir] {
                    ModificationNotes(data: data, state: state)
                }
            }
            if !state.editingNotes.isEmpty { Text("有意见正在编辑，请先保存或放弃编辑再继续。").foregroundStyle(Palette.warning) }
            SettingsGroup(title: "代码材料（不调用 AI）") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Picker("处理方式", selection: $state.codeMode) {
                        Text("不动").tag("none")
                        Text("按各自模板重排").tag("keep")
                        Text("在启用模板里平均分配").tag("balance")
                        Text("统一换成某个模板").tag("fixed")
                    }
                    if state.codeMode == "fixed" {
                        Picker("模板", selection: $state.templateId) {
                            ForEach(state.model.settings.codeTemplates.enabled) { Text($0.label).tag($0.id) }
                        }
                    }
                    Text("仅处理已有交付包的项目；PDF 随交付包自动更新。").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                }.padding(Spacing.lg)
            }
            SettingsGroup(title: "重做方式（调用收费模型）") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Picker("重做方式", selection: $state.force) {
                        Text("按意见修改").tag("none")
                        Text("只重写文字").tag("rewrite")
                        Text("从头重做").tag("regenerate")
                    }.pickerStyle(.segmented).labelsHidden().disabled(state.hasDraft)
                    Text(state.force == "none" ? "先整理意见，再逐项预览。" : "本次不执行清单里的意见，已保存意见仍保留。重写或重做会产生模型费用。")
                        .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                }.padding(Spacing.lg)
            }
        }
    }
    func changeNames(_ remove: Bool) {
        let text = pasted
        Task {
            state.busy = true
            await state.addNames(text, remove: remove)
            if state.missing.isEmpty { pasted = "" }
            state.busy = false
        }
    }
}
