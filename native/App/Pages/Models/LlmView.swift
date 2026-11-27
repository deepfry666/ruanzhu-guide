import StudioCore
import SwiftUI

extension LlmVendor {
    static func draft(_ preset: String = "deepseek") -> LlmVendor {
        let info = LLM_PRESETS[preset]!
        return LlmVendor(id: "", name: info.label, preset: preset, baseUrl: info.baseUrl, jsonMode: info.jsonMode)
    }
}

struct LlmView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LlmVendor?
    @State private var deleting: LlmVendor?

    var body: some View {
        let vendors = model.settings.llm.vendors
        PageScroll {
            SettingsGroup(
                title: "厂商",
                trailing: AnyView(
                    Button { editing = .draft() } label: { Label("添加厂商", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .help("添加厂商")
                )
            ) {
                if vendors.isEmpty {
                    Text("还没有大模型厂商，点「添加厂商」")
                        .textStyle(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Spacing.lg)
                } else {
                    ForEach(vendors) { vendor in
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack(spacing: Spacing.sm) {
                                    Text(vendor.name).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                                    TagView(text: LLM_PRESETS[vendor.preset]?.label ?? vendor.preset)
                                    if !(model.vendorKeys[vendor.id] ?? false) { TagView(text: "没有密钥", tone: .red) }
                                }
                                Text(vendor.baseUrl)
                                    .font(Typography.caption.font.monospaced())
                                    .foregroundStyle(Palette.textSecondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(vendor.models.isEmpty ? "—" : "已获取 \(vendor.models.count) 个模型")
                                .textStyle(Typography.body.number)
                                .foregroundStyle(Palette.textSecondary)
                            Button("获取模型", systemImage: "arrow.triangle.2.circlepath") { fetchModels(vendor) }
                                .buttonStyle(.secondary)
                            Button { editing = vendor } label: { Image(systemName: "pencil") }
                                .buttonStyle(.iconAction)
                                .help("编辑")
                            Button(role: .destructive) { deleting = vendor } label: { Image(systemName: "trash") }
                                .buttonStyle(.iconAction)
                                .help("删除")
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                    }
                }
            }
            SettingsGroup(title: "各步骤使用的模型") {
                ForEach(LLM_STEP_ORDER, id: \.self) { step in
                    AssignmentRow(step: step, info: LLM_STEPS[step]!)
                        .id("\(step)#\(model.settingsRevision)")
                }
            }
        }
        .sheet(item: $editing) { vendor in
            VendorEditor(vendor: vendor, hasKey: model.vendorKeys[vendor.id] ?? false) {
                editing = nil
                Task { await model.reloadSettings() }
            }
            .environment(model).designSystem()
            .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        }
        .confirmationDialog(deleting.map { "删除「\($0.name)」？" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let vendor = deleting else { return }
                Task {
                    await model.perform { try await model.core?.deleteVendor(vendor.id) }
                    await model.reloadSettings()
                }
            }
        } message: {
            Text("用到它的步骤会被清空。")
        }
    }

    func fetchModels(_ vendor: LlmVendor) {
        Task {
            do {
                let models = try await model.core?.fetchVendorModels(vendor.id) ?? []
                model.toast(.success, "获取到 \(models.count) 个模型")
                await model.reloadSettings()
            } catch {
                model.toast(.error, "获取失败：\(messageOf(error))（可以直接手动填写模型名）")
            }
        }
    }
}

struct AssignmentRow: View {
    let step: String
    let info: LlmStepInfo
    @Environment(AppModel.self) private var model
    @State private var vendorId = ""
    @State private var modelName = ""
    @State private var modelError = false
    @State private var shakeTrigger = 0
    @State private var testing = false
    /// 测试结果：没问题时只弹提示；有问题时打开窗口，写明线路回了什么
    @State private var report: (title: String, summary: String, details: String)?

    var vendor: LlmVendor? { model.settings.llm.vendors.first { $0.id == vendorId } }
    var suggestions: [String] {
        guard let vendor else { return [] }
        return uniqued(vendor.models + (LLM_PRESETS[vendor.preset]?.suggestedModels ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(info.label).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                    if info.needsVision {
                        Text("需要看图模型").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                    if let fallback = info.fallback {
                        Text("不选时用「\(LLM_STEPS[fallback]?.label ?? fallback)」的模型")
                            .textStyle(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(width: 170, alignment: .leading)
                Picker("", selection: $vendorId) {
                    Text(info.fallback.map { "跟随「\(LLM_STEPS[$0]?.label ?? $0)」" } ?? "不使用").tag("")
                    ForEach(model.settings.llm.vendors) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 200)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        TextField("模型名", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                            .overlay(Radius.shape(Radius.small).strokeBorder(modelError ? Palette.danger : Palette.divider, lineWidth: Palette.hairline))
                            .overlay(Radius.shape(Radius.small).strokeBorder(Palette.errorRing, lineWidth: modelError ? Palette.ringWidth : 0))
                            .shake(trigger: shakeTrigger)
                            .onChange(of: modelName) { _, _ in modelError = false }
                        if !suggestions.isEmpty {
                            Menu {
                                ForEach(suggestions, id: \.self) { item in Button(item) { modelName = item } }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    if modelError {
                        Text("请填写模型名").textStyle(Typography.caption).foregroundStyle(Palette.danger)
                    }
                }
                .frame(width: 260)
                Spacer()
                Button("保存") { save() }.buttonStyle(.primary)
                Button {
                    test()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试") }
                }
                .buttonStyle(.secondary)
                .disabled(vendorId.isEmpty || modelName.isEmpty || testing)
            }
            if info.needsVision, vendor?.preset == "deepseek" {
                Banner(.warning, "DeepSeek 目前没有看图模型，这一步建议改用 OpenAI 或智谱的看图模型")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .onAppear {
            let current = model.settings.llm.ownAssignment(step)
            vendorId = current?.vendorId ?? ""
            modelName = current?.model ?? ""
        }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(report?.title ?? "").textStyle(Typography.title).foregroundStyle(Palette.text)
                Text(report?.summary ?? "").textStyle(Typography.body).foregroundStyle(Palette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let details = report?.details, !details.isEmpty {
                    Text("线路回的内容（结束原因、正文、推理内容、原始返回）").textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                    ScrollView {
                        Text(details)
                            .font(Typography.body.font.monospaced())
                            .foregroundStyle(Palette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Spacing.md)
                    .surface(Radius.medium, fill: Palette.windowBackground)
                    .frame(minHeight: 260)
                }
                HStack(spacing: Spacing.sm) {
                    Button("复制全部") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString([report?.title, report?.summary, report?.details].compactMap { $0 }.joined(separator: "\n\n"), forType: .string)
                        model.toast(.success, "已复制")
                    }
                    Spacer()
                    Button("好") { report = nil }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.xl)
            .frame(width: 680)
            .background(Palette.card)
            .designSystem()
            .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        }
    }

    func save() {
        if !vendorId.isEmpty, modelName.jsTrimmed.isEmpty {
            modelError = true
            shakeTrigger += 1
            model.toast(.warning, "请填写模型名（可以先点厂商的「获取模型」再从下拉里选）")
            return
        }
        let value = vendorId.isEmpty || modelName.jsTrimmed.isEmpty ? nil : LlmAssignment(vendorId: vendorId, model: modelName.jsTrimmed)
        Task {
            let cleared = info.fallback.map { "「\(info.label)」改为跟随「\(LLM_STEPS[$0]?.label ?? $0)」的模型" } ?? "「\(info.label)」已清空，不使用大模型"
            await model.perform(value == nil ? cleared : "「\(info.label)」已保存") {
                try await model.core?.setAssignment(step, value)
            }
            await model.reloadSettings()
        }
    }

    func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                guard let result = try await model.core?.testVendor(vendorId, model: modelName, vision: info.needsVision) else { return }
                if let problem = result.jsonProblem {
                    report = ("能连上，但不能按 JSON 输出", "一句话测试的回复：\(result.reply.isEmpty ? "（空）" : result.reply)\n按 JSON 输出时：\(problem)\n\n规划、检查截图、写文字都需要模型按 JSON 输出，这条线路用来做这些步骤会失败。", result.diagnostics ?? "")
                } else if let diagnostics = result.diagnostics {
                    report = ("能按 JSON 输出，但一句话测试没有回正文", "回复：（空）", diagnostics)
                } else {
                    model.toast(.success, "可用（\(Int(result.ms)) 毫秒），能按 JSON 输出：\(result.reply)")
                }
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct VendorEditor: View {
    let vendor: LlmVendor
    let hasKey: Bool
    let onSaved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LlmVendor
    @State private var apiKey = ""
    @State private var nameError = false
    @State private var shakeTrigger = 0
    @State private var busy = false

    init(vendor: LlmVendor, hasKey: Bool, onSaved: @escaping () -> Void) {
        self.vendor = vendor
        self.hasKey = hasKey
        self.onSaved = onSaved
        _draft = State(initialValue: vendor)
    }

    var isNew: Bool { vendor.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(isNew ? "添加大模型厂商" : "编辑：\(vendor.name)").textStyle(Typography.title).foregroundStyle(Palette.text)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("厂商").textStyle(Typography.captionStrong).foregroundStyle(Palette.textSecondary)
                Picker("", selection: Binding(get: { draft.preset }, set: { key in
                    let preset = LLM_PRESETS[key]!
                    draft.preset = key
                    draft.name = preset.label
                    draft.baseUrl = preset.baseUrl
                    draft.jsonMode = preset.jsonMode
                })) {
                    ForEach(LLM_PRESET_ORDER, id: \.self) { Text(LLM_PRESETS[$0]!.label).tag($0) }
                }
                // 分段按钮每段一样宽，按最长的「OpenAI 兼容（自定义 / CPA）」撑开会超出弹窗，改用下拉
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            labeled("名称", error: nameError ? "请填写名称" : nil) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .overlay(Radius.shape(Radius.small).strokeBorder(nameError ? Palette.danger : Palette.divider, lineWidth: Palette.hairline))
                    .overlay(Radius.shape(Radius.small).strokeBorder(Palette.errorRing, lineWidth: nameError ? Palette.ringWidth : 0))
                    .shake(trigger: shakeTrigger)
                    .onChange(of: draft.name) { _, _ in nameError = false }
            }
            labeled("接口地址") { TextField("https://.../v1", text: $draft.baseUrl).textFieldStyle(.roundedBorder) }
            labeled("密钥", hint: !isNew && hasKey ? "已保存，留空表示不修改" : "加密保存在本机") { SecureField("", text: $apiKey).textFieldStyle(.roundedBorder) }
            Toggle("要求返回 JSON 格式（不支持的模型会自动降级）", isOn: $draft.jsonMode).toggleStyle(.switch)
            HStack(spacing: Spacing.sm) {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if draft.name.jsTrimmed.isEmpty {
                        nameError = true
                        shakeTrigger += 1
                        return model.toast(.warning, "请填写名称")
                    }
                    busy = true
                    Task {
                        defer { busy = false }
                        if await model.perform(nil, { _ = try await model.core?.saveVendor(draft, apiKey: apiKey.isEmpty ? nil : apiKey) }) {
                            dismiss()
                            onSaved()
                        }
                    }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .background(Palette.card)
    }

    func labeled<Content: View>(_ label: String, hint: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).textStyle(Typography.captionStrong).foregroundStyle(Palette.textSecondary)
            content()
            if let error {
                Text(error).textStyle(Typography.caption).foregroundStyle(Palette.danger)
            } else if let hint {
                Text(hint).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}
