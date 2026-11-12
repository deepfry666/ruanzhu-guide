import StudioCore
import SwiftUI

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
    @Binding var busy: Bool
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SettingsGroup(
                        title: "软件名（每行一个，已填 \(count) 个）", footer: "也可以在名字后面用逗号带上：截图数,重点功能,补充说明",
                        trailing: AnyView(
                            Button("从文件读取…") {
                                if let file = Panels.chooseFiles("选择 CSV 或文本文件", extensions: ["csv", "txt", "tsv"], multiple: false).first {
                                    text = FS.readTextIfExists(file) ?? ""
                                }
                            }
                            .buttonStyle(.textAction)
                        )
                    ) {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("软件名称A V1.0\n软件名称B V1.0,7,重点功能\n软件名称C V1.0").foregroundStyle(Palette.textSecondary).padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.sm)
                            }
                            TextEditor(text: $text).textStyle(Typography.body).scrollContentBackground(.hidden).frame(minHeight: Metrics.textAreaMinHeight * 2)
                        }
                        .padding(Spacing.sm)
                        if !flagged.isEmpty {
                            Text("这些名称可能被认为涉及政府职能，会写成个人自用的工具，最好换个名称：\(flagged.joined(separator: "、"))")
                                .textStyle(Typography.caption).foregroundStyle(Palette.warning).padding(.horizontal, Spacing.md).padding(.bottom, Spacing.sm)
                        }
                    }
                    SettingsGroup(title: "生成选项") {
                        ScreenCountRow(hint: "没在列表里写截图数的项目", autoCount: $autoCount, screenCount: $screenCount)
                        SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                            Picker("", selection: $platform) {
                                ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                            }
                            .labelsHidden()
                            .frame(width: Metrics.sidebarWidth, alignment: .trailing)
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
                .padding(Spacing.xl)
            }
            Divider()
            HStack(spacing: Spacing.sm) {
                Spacer()
                Button("取消") { model.newProjectPresented = false }
                    .keyboardShortcut(.cancelAction)
                MorphButton(title: "创建 \(count > 0 ? "\(count) " : "")个项目", doneTitle: "已创建") { await submit() }

                    .disabled(busy || count == 0)
            }
            .padding(Spacing.xl)
            .disabled(busy)
        }
        .onAppear {
            screenCount = defaultScreens
            platform = PLATFORMS.contains { $0.value == defaultPlatform } ? defaultPlatform : PLATFORMS[0].value
            contentDate = localDateKey()
        }
        .sheet(isPresented: Binding(get: { conflicts != nil }, set: { if !$0 { conflicts = nil } })) {
            NameConflictSheet(conflicts: conflicts ?? [], total: count) { chosen in
                conflicts = nil
                Task { _ = await create(regenerate: chosen) }
            } cancel: {
                conflicts = nil
            }
        }
    }

    /// 先查名单里有没有已经做过的，有就让用户逐个选；没有直接创建
    func submit() async -> Bool {
        guard !busy else { return false }
        guard let core = model.core else { return false }
        busy = true
        defer { busy = false }
        do {
            let found = try await core.nameConflicts(parseBatchList(text).map(\.softwareName))
            if found.isEmpty { return await create(regenerate: []) }
            conflicts = found
            return false
        } catch {
            model.toast(.error, messageOf(error))
            return false
        }
    }

    func create(regenerate: Set<String>) async -> Bool {
        guard let core = model.core else { return false }
        busy = true
        defer { busy = false }
        do {
            let result = try await core.createProjectsFromList(
                text, screenCount: autoCount ? nil : screenCount, platform: platform, wantDesign: wantDesign, contentDate: contentDate.jsTrimmed, earliestDate: earliestDate.jsTrimmed, codeTemplateId: templateId.isEmpty ? nil : templateId,
                regenerate: regenerate)
            if startNow, !result.created.isEmpty { await core.batch.enqueue(result.created) }
            text = ""
            await model.reloadProjects()
            let again = result.regenerated.isEmpty ? "" : "，重新生成 \(result.regenerated.count) 个"
            if result.errors.isEmpty {
                model.toast(.success, "已创建 \(result.created.count) 个项目\(again)")
            } else {
                model.alert = AlertItem(title: "创建了 \(result.created.count) 个\(again)，\(result.errors.count) 个没有创建", message: result.errors.joined(separator: "\n"))
            }
            model.newProjectPresented = false
            model.go(.projects)
            return true
        } catch {
            model.toast(.error, messageOf(error))
            return false
        }
    }
}

/// 同名项目上次生成的时间（弹窗说明用）
func lastBuildText(_ item: JSON?) -> String {
    guard let at = item?["lastBuildAt"]?.string else { return "这个项目还没出过交付包。" }
    return "上次生成：\(formatTime(at))。"
}

/// 批量新建时名单里有已经做过的项目：每个选「跳过（手误）」或「重新生成」，选了重新生成的再统一确认一次。
struct NameConflictSheet: View {
    let conflicts: [JSON]
    let total: Int
    let proceed: (Set<String>) -> Void
    let cancel: () -> Void
    @State private var regenerate: Set<String> = []
    @State private var confirm = false

    var candidates: [JSON] { conflicts.filter { $0["canRegenerate"].isTruthy } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("名单里有 \(conflicts.count) 个已经做过").textStyle(Typography.title)
            Text("默认跳过（当作手误）。要重新生成的打开开关；已提交或正在运行的只能跳过。").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(conflicts.indices, id: \.self) { index in
                        let item = conflicts[index]
                        let name = item["name"].text
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                Text(item["canRegenerate"].isTruthy ? lastBuildText(item) : item["reason"].text).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            if item["canRegenerate"].isTruthy {
                                Toggle("重新生成", isOn: Binding(get: { regenerate.contains(name) }, set: { if $0 { regenerate.insert(name) } else { regenerate.remove(name) } }))
                                    .toggleStyle(.switch)
                            } else {
                                Text("跳过").foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: Metrics.dialogConfirmWidth, minHeight: Metrics.textAreaMinHeight, maxHeight: Metrics.dialogNewWidth / 2)
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
        .padding(Spacing.xl)
        .alert("确定重新生成 \(regenerate.count) 个项目？", isPresented: $confirm) {
            Button("重新生成", role: .destructive) { proceed(regenerate) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(regenerate.sorted().prefix(5).joined(separator: "、"))\(regenerate.count > 5 ? " 等" : "")：旧的规划、截图和说明先归档到各自项目的 archive 文件夹，然后按这次填的设置从头重新生成。代码来源不变。")
        }
    }
}
