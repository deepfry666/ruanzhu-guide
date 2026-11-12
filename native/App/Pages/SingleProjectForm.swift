import StudioCore
import SwiftUI

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
    @Binding var busy: Bool
    @State private var nameError = false
    @State private var shakeTrigger = 0
    /// 同名项目：先问是重新生成还是手误，选重新生成再确认一次
    @State private var conflict: JSON?
    @State private var confirmRegenerate = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let version = detectVersion(name)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SettingsGroup(title: "基本信息") {
                        SettingsRow(label: "软件名", hint: softwareNameRedLineHint(name) ?? (name.jsTrimmed.isEmpty ? "含版本号，按原样填写" : version.map { "识别到版本号 \($0)" } ?? "没有版本号"), info: "只用于文件名、文档标题和页眉，截图里不会出现软件名和版本号。") {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                TextField("例如：软件名称 V1.0", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: Metrics.editorImageWidth)
                                    .focused($nameFocused)
                                    .onSubmit { Task { _ = await submit(runNow: true) } }
                                    .overlay(Radius.shape(Radius.small).strokeBorder(nameError ? Palette.danger : Palette.divider, lineWidth: Palette.hairline))
                                    .overlay(Radius.shape(Radius.small).strokeBorder(Palette.errorRing, lineWidth: nameError ? Palette.ringWidth : 0))
                                    .shake(trigger: shakeTrigger)
                                    .onChange(of: name) { _, _ in nameError = false }
                                if nameError { Text("请填写软件名").textStyle(Typography.caption).foregroundStyle(Palette.danger) }
                            }
                        }
                        ScreenCountRow(autoCount: $autoCount, screenCount: $screenCount)
                        SettingsRow(label: "重点功能") {
                            TextField("可选，例如：违章查询、在线缴费", text: $emphasis).textFieldStyle(.roundedBorder).frame(maxWidth: Metrics.editorImageWidth)
                        }
                        SettingsRow(label: "补充说明") {
                            TextField("可选，目标用户、风格偏好等", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).frame(maxWidth: Metrics.editorImageWidth)
                        }
                    }
                    SettingsGroup(title: "生成选项") {
                        SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                            Picker("", selection: $platform) {
                                ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                            }
                            .labelsHidden()
                            .frame(width: Metrics.sidebarWidth, alignment: .trailing)
                        }
                        ContentDateRows(contentDate: $contentDate, earliestDate: $earliestDate)
                        SettingsRow(label: "设计说明章节") {
                            Toggle("", isOn: $wantDesign).toggleStyle(.switch).labelsHidden()
                        }
                        CodeTemplateRow(templateId: $templateId)
                    }
                }
                .padding(Spacing.xl)
            }
            Divider()
            HStack(spacing: Spacing.sm) {
                Button("只创建") { Task { _ = await submit(runNow: false) } }
                    .buttonStyle(.secondary)

                Spacer()
                Button("取消") { model.newProjectPresented = false }
                    .keyboardShortcut(.cancelAction)
                MorphButton(title: "创建并开始") { await submit(runNow: true) }

                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.xl)
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
                model.newProjectPresented = false
                model.openProject(dir)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }

    func submit(runNow: Bool) async -> Bool {
        guard !busy else { return false }
        guard !name.jsTrimmed.isEmpty else {
            nameError = true
            shakeTrigger += 1
            nameFocused = true
            model.toast(.warning, "请填写软件名")
            return false
        }
        guard let core = model.core else { return false }
        busy = true
        defer { busy = false }
        do {
            if let found = try await core.nameConflicts([name.jsTrimmed]).first {
                if found["canRegenerate"].isTruthy { conflict = found } else { model.toast(.error, "已经有「\(found["name"].text)」：\(found["reason"].text)") }
                return false
            }
            let dir = try await core.createProject(request)
            if runNow { core.run(dir) }
            await model.reloadProjects()
            name = ""
            emphasis = ""
            notes = ""
            model.newProjectPresented = false
            model.openProject(dir)
            return true
        } catch {
            model.toast(.error, messageOf(error))
            return false
        }
    }
}
