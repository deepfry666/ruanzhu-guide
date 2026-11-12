import StudioCore
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = "single"

    var body: some View {
        PageScroll(maxWidth: 1100) {
            if mode == "single" {
                SingleProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform)
                    .id(model.settingsRevision)
            } else {
                BatchProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform)
                    .id(model.settingsRevision)
            }
        }
        .navigationTitle("新建项目")
        .onChange(of: model.devNewMode) { _, next in if let next { mode = next } }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    Text("单个项目").tag("single")
                    Text("批量新建").tag("batch")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// 代码模板：默认按设置里的分配规则（轮流平均分），也可以指定一个。
struct CodeTemplateRow: View {
    @Environment(AppModel.self) private var model
    @Binding var templateId: String
    /// 批量新建时显示这一批会怎么分
    var batchCount: Int? = nil
    @State private var preview: [String] = []

    var autoLabel: String {
        let library = model.settings.codeTemplates
        if library.assign == "fixed", let fixed = library.entry(library.fixedId), fixed.enabled { return "自动（\(fixed.label)）" }
        return "自动（轮流平均分）"
    }

    var summary: String? {
        guard batchCount != nil, !preview.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for label in preview { counts[label, default: 0] += 1 }
        return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { "\($0.key) × \($0.value)" }.joined(separator: "、")
    }

    var body: some View {
        let enabled = model.settings.codeTemplates.enabled
        SettingsRow(label: "代码模板", hint: enabled.isEmpty ? "还没有模板，交付包只有说明书 3 个文件" : summary.map { "这一批：\($0)" }, info: "在「设置 → 代码模板」里加模板、设分配方式。52 行版固定 60 页，每页 52 行非空原始代码；历史版沿用原版式。页眉换成软件名。") {
            if enabled.isEmpty {
                Button("去添加") { model.go(.settings, tab: "code") }.buttonStyle(.borderless)
            } else {
                Picker("", selection: $templateId) {
                    Text(autoLabel).tag("")
                    ForEach(enabled) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 200, alignment: .trailing)
            }
        }
        .task(id: "\(batchCount ?? -1)|\(templateId)|\(model.settingsRevision)") {
            guard let batchCount, batchCount > 0 else { preview = []; return }
            preview = (try? await model.core?.previewCodeTemplateAssignment(count: batchCount, fixedId: templateId.isEmpty ? nil : templateId)) ?? []
        }
    }
}

/// 内容日期（截图里的「今天」）和最早日期（历史记录最早到哪天）。
struct ContentDateRows: View {
    @Binding var contentDate: String
    @Binding var earliestDate: String

    var body: some View {
        SettingsRow(label: "内容日期", hint: "截图里的「今天」，默认新建当天") {
            TextField(localDateKey(), text: $contentDate).textFieldStyle(.roundedBorder).frame(width: 150)
        }
        SettingsRow(label: "最早日期", hint: "选填；不填时历史记录只在内容日期前 \(DEFAULT_HISTORY_DAYS) 天内", info: "可填企业成立日期或开发完成日期。截图和正文里的流水、订单、动态等历史记录不会早于这一天；预约、截止等未来安排不受限。") {
            TextField("YYYY-MM-DD", text: $earliestDate).textFieldStyle(.roundedBorder).frame(width: 150)
        }
    }
}

struct ScreenCountRow: View {
    var hint: String? = nil
    @Binding var autoCount: Bool
    @Binding var screenCount: Int

    var body: some View {
        SettingsRow(label: "截图数", hint: hint) {
            Picker("", selection: $autoCount) {
                Text("固定").tag(false)
                Text("按功能决定").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !autoCount {
                NumberField(value: screenCount, range: 2...15, suffix: "屏", width: 44) { screenCount = $0 }
            }
        }
    }
}

struct SingleProjectForm: View {
    let defaultScreens: Int
    let defaultPlatform: String
    @Environment(AppModel.self) private var model
    @State private var name = ""
    // 默认固定屏数（设置里的「默认截图数」，默认 7），也可以改成让大模型按功能决定
    @State private var autoCount = false
    @State private var screenCount = 7
    @State private var emphasis = ""
    @State private var notes = ""
    @State private var platform = ""
    @State private var wantDesign = false
    @State private var contentDate = localDateKey()
    @State private var earliestDate = ""
    @State private var templateId = ""
    @State private var busy = false
    /// 同名项目：先问是重新生成还是手误，选重新生成再确认一次
    @State private var conflict: JSON?
    @State private var confirmRegenerate = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let version = detectVersion(name)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SettingsGroup(title: "基本信息") {
                    SettingsRow(label: "软件名", hint: softwareNameRedLineHint(name) ?? (name.jsTrimmed.isEmpty ? "含版本号，按原样填写" : version.map { "识别到版本号 \($0)" } ?? "没有版本号"), info: "只用于文件名、文档标题和页眉，截图里不会出现软件名和版本号。") {
                        TextField("例如：软件名称 V1.0", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                            .focused($nameFocused)
                            .onSubmit { submit(runNow: true) }
                    }
                    ScreenCountRow(autoCount: $autoCount, screenCount: $screenCount)
                    SettingsRow(label: "重点功能") {
                        TextField("可选，例如：违章查询、在线缴费", text: $emphasis).textFieldStyle(.roundedBorder).frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                    }
                    SettingsRow(label: "补充说明") {
                        TextField("可选，目标用户、风格偏好等", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                    }
                }
                SettingsGroup(title: "生成选项") {
                    SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                        Picker("", selection: $platform) {
                            ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(width: 240, alignment: .trailing)
                    }
                    ContentDateRows(contentDate: $contentDate, earliestDate: $earliestDate)
                    SettingsRow(label: "设计说明章节") {
                        Toggle("", isOn: $wantDesign).toggleStyle(.switch).labelsHidden()
                    }
                    CodeTemplateRow(templateId: $templateId)
                }
            }
            HStack {
                Spacer()
                Button("只创建") { submit(runNow: false) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button("创建并开始") { submit(runNow: true) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .onAppear {
            screenCount = defaultScreens
            platform = PLATFORMS.contains { $0.value == defaultPlatform } ? defaultPlatform : PLATFORMS[0].value
            contentDate = localDateKey()
            nameFocused = true
        }
        .confirmationDialog("「\(conflict?["name"].text ?? "")」已经做过", isPresented: Binding(get: { conflict != nil && !confirmRegenerate }, set: { if !$0, !confirmRegenerate { conflict = nil } }), titleVisibility: .visible) {
            Button("重新生成…") { DispatchQueue.main.async { confirmRegenerate = true } }
            Button("手误，不创建", role: .cancel) { conflict = nil }
        } message: {
            Text(lastBuildText(conflict) + "要重新生成，还是名字输错了？")
        }
        .alert("确定重新生成「\(conflict?["name"].text ?? "")」？", isPresented: $confirmRegenerate) {
            Button("重新生成", role: .destructive) { regenerate() }
            Button("取消", role: .cancel) { conflict = nil }
        } message: {
            Text("旧的规划、截图和说明先归档到项目的 archive 文件夹，交付包在重新出包时归档，然后按这次填的设置从头重新生成。代码来源不变。")
        }
    }

    var request: JSON {
        .obj([
            "softwareName": .string(name.jsTrimmed), "screenCount": autoCount ? .null : .number(Double(screenCount)),
            "emphasis": .string(emphasis), "notes": .string(notes), "platform": .string(platform), "wantDesign": .bool(wantDesign),
            "contentDate": .string(contentDate.jsTrimmed), "earliestDate": .string(earliestDate.jsTrimmed),
            "codeTemplateId": .string(templateId),
        ])
    }

    func regenerate() {
        guard let core = model.core, let dir = conflict?["dir"]?.string else { return }
        let request = request
        conflict = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await core.regenerateProject(dir, request)
                await model.reloadProjects()
                name = ""
                emphasis = ""
                notes = ""
                model.toast(.success, "已开始重新生成")
                model.openProject(dir)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }

    func submit(runNow: Bool) {
        guard !name.jsTrimmed.isEmpty else {
            model.toast(.warning, "请填写软件名")
            return
        }
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let found = try await core.nameConflicts([name.jsTrimmed]).first {
                    if found["canRegenerate"].isTruthy { conflict = found }
                    else { model.toast(.error, "已经有「\(found["name"].text)」：\(found["reason"].text)") }
                    return
                }
                let dir = try await core.createProject(request)
                if runNow { core.run(dir) }
                await model.reloadProjects()
                name = ""
                emphasis = ""
                notes = ""
                model.openProject(dir)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct BatchProjectForm: View {
    let defaultScreens: Int
    let defaultPlatform: String
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var autoCount = false
    @State private var screenCount = 7
    @State private var platform = ""
    @State private var wantDesign = false
    @State private var contentDate = localDateKey()
    @State private var earliestDate = ""
    @State private var startNow = true
    @State private var templateId = ""
    @State private var busy = false
    /// 名单里已经做过的项目：逐个选跳过还是重新生成
    @State private var conflicts: [JSON]?

    var count: Int {
        Rx.split(#"\r?\n"#, text).filter { line in
            let trimmed = line.jsTrimmed
            return !trimmed.isEmpty && !Rx.test("^(软件名|名称|name)[,，\\t]", trimmed, "i")
        }.count
    }

    /// 名称里带政务、公安这类字样的
    var flagged: [String] {
        Rx.split(#"\r?\n"#, text).compactMap { line in
            let name = Rx.split("[,，\\t]", line.jsTrimmed).first?.jsTrimmed ?? ""
            return !name.isEmpty && softwareNameRedLineHint(name) != nil ? name : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SettingsGroup(title: "软件名（每行一个，已填 \(count) 个）", footer: "也可以在名字后面用逗号带上：截图数,重点功能,补充说明", trailing: AnyView(
                    Button("从文件读取…") {
                        if let file = Panels.chooseFiles("选择 CSV 或文本文件", extensions: ["csv", "txt", "tsv"], multiple: false).first {
                            text = FS.readTextIfExists(file) ?? ""
                        }
                    }
                    .buttonStyle(.borderless)
                )) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("软件名称A V1.0\n软件名称B V1.0,7,重点功能\n软件名称C V1.0").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                        }
                        TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(minHeight: 260)
                    }
                    .padding(8)
                    if !flagged.isEmpty {
                        Text("这些名称可能被认为涉及政府职能，会写成个人自用的工具，最好换个名称：\(flagged.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
                SettingsGroup(title: "生成选项") {
                    ScreenCountRow(hint: "没在列表里写截图数的项目", autoCount: $autoCount, screenCount: $screenCount)
                    SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                        Picker("", selection: $platform) {
                            ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(width: 240, alignment: .trailing)
                    }
                    ContentDateRows(contentDate: $contentDate, earliestDate: $earliestDate)
                    SettingsRow(label: "设计说明章节") { Toggle("", isOn: $wantDesign).toggleStyle(.switch).labelsHidden() }
                    CodeTemplateRow(templateId: $templateId, batchCount: count)
                    SettingsRow(label: "创建后直接开始", hint: "不停下确认规划") {
                        Toggle("", isOn: $startNow).toggleStyle(.switch).labelsHidden()
                    }
                    // 默认就是设置里的值；在这里改会同时改设置，正在跑的批量也立刻按新值调整
                    SettingsRow(label: "同时处理项目", hint: "不限：全部同时开跑") {
                        ConcurrencyPicker(value: model.settings.pipeline.batchConcurrency, presets: PROJECT_CONCURRENCY_PRESETS, unit: "个") { model.saveSettings(["pipeline": ["batchConcurrency": .number(Double($0))]]) }
                    }
                    SettingsRow(label: "生图并发上限", hint: "所有项目合计；不限时只受每条线路自己的上限约束") {
                        ConcurrencyPicker(value: model.settings.image.globalConcurrency, presets: IMAGE_CONCURRENCY_PRESETS, unit: "张") { model.saveSettings(["image": ["globalConcurrency": .number(Double($0))]]) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("创建 \(count > 0 ? "\(count) " : "")个项目") { submit() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(busy || count == 0)
            }
        }
        .onAppear {
            screenCount = defaultScreens
            platform = PLATFORMS.contains { $0.value == defaultPlatform } ? defaultPlatform : PLATFORMS[0].value
            contentDate = localDateKey()
        }
        .sheet(isPresented: Binding(get: { conflicts != nil }, set: { if !$0 { conflicts = nil } })) {
            NameConflictSheet(conflicts: conflicts ?? [], total: count) { chosen in
                conflicts = nil
                create(regenerate: chosen)
            } cancel: {
                conflicts = nil
            }
        }
    }

    /// 先查名单里有没有已经做过的，有就让用户逐个选；没有直接创建
    func submit() {
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let found = try await core.nameConflicts(parseBatchList(text).map(\.softwareName))
                if found.isEmpty { create(regenerate: []) } else { conflicts = found }
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }

    func create(regenerate: Set<String>) {
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await core.createProjectsFromList(text, screenCount: autoCount ? nil : screenCount, platform: platform, wantDesign: wantDesign, contentDate: contentDate.jsTrimmed, earliestDate: earliestDate.jsTrimmed, codeTemplateId: templateId.isEmpty ? nil : templateId, regenerate: regenerate)
                if startNow, !result.created.isEmpty { await core.batch.enqueue(result.created) }
                text = ""
                await model.reloadProjects()
                let again = result.regenerated.isEmpty ? "" : "，重新生成 \(result.regenerated.count) 个"
                if result.errors.isEmpty {
                    model.toast(.success, "已创建 \(result.created.count) 个项目\(again)")
                } else {
                    model.alert = AlertItem(title: "创建了 \(result.created.count) 个\(again)，\(result.errors.count) 个没有创建", message: result.errors.joined(separator: "\n"))
                }
                model.go(.projects)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

/// 同名项目上次生成的时间（弹窗说明用）
private func lastBuildText(_ item: JSON?) -> String {
    guard let at = item?["lastBuildAt"]?.string else { return "这个项目还没出过交付包。" }
    return "上次生成：\(formatTime(at))。"
}

/// 批量新建时名单里有已经做过的项目：每个选「跳过（手误）」或「重新生成」，选了重新生成的再统一确认一次。
private struct NameConflictSheet: View {
    let conflicts: [JSON]
    let total: Int
    let proceed: (Set<String>) -> Void
    let cancel: () -> Void
    @State private var regenerate: Set<String> = []
    @State private var confirm = false

    var candidates: [JSON] { conflicts.filter { $0["canRegenerate"].isTruthy } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("名单里有 \(conflicts.count) 个已经做过").font(.headline)
            Text("默认跳过（当作手误）。要重新生成的打开开关；已提交或正在运行的只能跳过。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conflicts.indices, id: \.self) { index in
                        let item = conflicts[index]
                        let name = item["name"].text
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                Text(item["canRegenerate"].isTruthy ? lastBuildText(item) : item["reason"].text).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item["canRegenerate"].isTruthy {
                                Toggle("重新生成", isOn: Binding(get: { regenerate.contains(name) }, set: { if $0 { regenerate.insert(name) } else { regenerate.remove(name) } }))
                                    .toggleStyle(.switch)
                            } else {
                                Text("跳过").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 480, minHeight: 140, maxHeight: 360)
            HStack {
                if !candidates.isEmpty {
                    Button("全部跳过") { regenerate = [] }
                    Button("全部重新生成") { regenerate = Set(candidates.map { $0["name"].text }) }
                }
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(regenerate.isEmpty ? "跳过这些，继续创建" : "继续") {
                    if regenerate.isEmpty { proceed([]) } else { confirm = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(total - conflicts.count + regenerate.count == 0 && regenerate.isEmpty)
            }
        }
        .padding(20)
        .alert("确定重新生成 \(regenerate.count) 个项目？", isPresented: $confirm) {
            Button("重新生成", role: .destructive) { proceed(regenerate) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(regenerate.sorted().prefix(5).joined(separator: "、"))\(regenerate.count > 5 ? " 等" : "")：旧的规划、截图和说明先归档到各自项目的 archive 文件夹，然后按这次填的设置从头重新生成。代码来源不变。")
        }
    }
}
