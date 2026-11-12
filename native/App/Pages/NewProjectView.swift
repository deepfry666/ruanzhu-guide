import StudioCore
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = "single"
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.lg) {
                Text("新建项目").textStyle(Typography.title)
                Spacer()
                SegmentedTabs(
                    selection: $mode,
                    items: [
                        .init(value: "single", title: "单个"),
                        .init(value: "batch", title: "批量"),
                    ]
                )
                .disabled(busy)
            }
            .padding(Spacing.xl)
            Divider()
            Group {
                if mode == "single" {
                    SingleProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform, busy: $busy)
                } else {
                    BatchProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform, busy: $busy)
                }
            }
            .id(model.settingsRevision)
        }
        .frame(width: Metrics.dialogNewWidth, height: Metrics.dialogNewWidth)
        .background(Palette.card)
        .foregroundStyle(Palette.text)
        .onAppear { mode = model.devNewMode == "batch" ? "batch" : "single" }
        .onChange(of: model.devNewMode) { _, next in if let next { mode = next } }
        .interactiveDismissDisabled()
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
                Button("去添加") {
                    model.newProjectPresented = false
                    model.go(.settings, tab: "code")
                }.buttonStyle(.textAction)
            } else {
                Picker("", selection: $templateId) {
                    Text(autoLabel).tag("")
                    ForEach(enabled) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: Metrics.sidebarWidth, alignment: .trailing)
            }
        }
        .task(id: "\(batchCount ?? -1)|\(templateId)|\(model.settingsRevision)") {
            guard let batchCount, batchCount > 0 else {
                preview = []
                return
            }
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
            TextField(localDateKey(), text: $contentDate).textFieldStyle(.roundedBorder).frame(width: Metrics.formLabelWidth + Spacing.xl)
        }
        SettingsRow(label: "最早日期", hint: "选填；不填时历史记录只在内容日期前 \(DEFAULT_HISTORY_DAYS) 天内", info: "可填企业成立日期或开发完成日期。截图和正文里的流水、订单、动态等历史记录不会早于这一天；预约、截止等未来安排不受限。") {
            TextField("YYYY-MM-DD", text: $earliestDate).textFieldStyle(.roundedBorder).frame(width: Metrics.formLabelWidth + Spacing.xl)
        }
    }
}

struct ScreenCountRow: View {
    var hint: String? = nil
    @Binding var autoCount: Bool
    @Binding var screenCount: Int

    var body: some View {
        SettingsRow(label: "截图数", hint: hint) {
            SegmentedTabs(selection: $autoCount, items: [.init(value: false, title: "固定"), .init(value: true, title: "按功能决定")])
                .fixedSize()
            if !autoCount {
                NumberField(value: screenCount, range: 2...15, suffix: "屏", width: Metrics.thumbnailList.width) { screenCount = $0 }
            }
        }
    }
}
