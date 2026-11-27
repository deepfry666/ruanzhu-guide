import StudioCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 代码模板：模板库。可以一次加多份；加入时就裁成正好 60 页 × 每页 50 行，之后每个项目原样使用、只换页眉。
struct CodeTemplateSettings: View {
    @Environment(AppModel.self) private var model
    @State private var library: JSON?
    @State private var adding = false
    @State private var results: [JSON]?
    @State private var usedBy: (label: String, names: [String])?
    @State private var removing: JSON?
    @State private var dropTargeted = false

    var entries: [JSON] { library?["entries"].items ?? [] }
    var enabled: [JSON] { entries.filter { $0["enabled"].isTruthy } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SettingsGroup(
                title: "代码模板（\(entries.count) 个）",
                footer: "52 行版固定为 60 页，每页 52 行非空原始代码，折行不重复计数。历史版保留原来的 50 个版面行规则；每份模板下方会标出版式。出包时只换页眉和页码。用过的模板不能删，可以停用。支持拖入 Word 文件。",
                trailing: AnyView(
                    Button(adding ? "正在检查…" : "添加模板…", systemImage: "plus") { choose() }
                        .buttonStyle(.textAction)
                        .disabled(adding)
                )
            ) {
                if entries.isEmpty {
                    SettingsRow(label: library == nil ? "正在读取…" : "还没有模板", hint: "点右上角「添加模板…」，选一份或多份代码 Word（.docx 或 .doc）")
                }
                ForEach(entries, id: \.["id"]) { entry in row(entry) }
            }
            .overlay {
                if dropTargeted { Radius.shape(Radius.large).strokeBorder(Palette.primary, lineWidth: 2) }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task { await add(await droppedFiles(providers)) }
                return true
            }
            SettingsGroup(title: "新项目怎么分配", footer: "新建项目时按这里分配模板；批量新建时在新建页还能改成全部用某一个。已有项目要换，在交付页或项目列表里换。") {
                SettingsRow(label: "分配方式") {
                    SegmentedTabs(
                        selection: Binding(get: { library?["assign"]?.string == "fixed" ? "fixed" : "balance" }, set: { setAssign($0, fixed: library?["fixedId"]?.string ?? enabled.first?["id"]?.string ?? "") }),
                        items: [
                            .init(value: "balance", title: "轮流平均分"),
                            .init(value: "fixed", title: "全部用同一个"),
                        ]
                    )
                    .fixedSize()
                }
                if library?["assign"]?.string == "fixed" {
                    SettingsRow(label: "用哪个模板") {
                        Picker("", selection: Binding(get: { library?["fixedId"]?.string ?? "" }, set: { setAssign("fixed", fixed: $0) })) {
                            ForEach(enabled, id: \.["id"]) { Text($0["label"].text).tag($0["id"]?.string ?? "") }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                } else {
                    SettingsRow(label: "规则", hint: "哪个模板用得少就先分给它，几个模板用的项目数保持差不多")
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            AddResultsSheet(results: results ?? []) { results = nil }.designSystem()
        }
        .sheet(isPresented: Binding(get: { usedBy != nil }, set: { if !$0 { usedBy = nil } })) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("用\(usedBy?.label ?? "")的项目（\(usedBy?.names.count ?? 0) 个）")
                    .textStyle(Typography.title).foregroundStyle(Palette.text)
                List(usedBy?.names ?? [], id: \.self) { Text($0).textStyle(Typography.body) }
                    .frame(minWidth: 360, minHeight: 300)
                    .clipShape(Radius.shape(Radius.medium))
                    .overlay(Radius.shape(Radius.medium).strokeBorder(Palette.divider, lineWidth: Palette.hairline))
                HStack { Spacer(); Button("好") { usedBy = nil }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
            }
            .padding(Spacing.xl)
            .background(Palette.card)
            .designSystem()
        }
        .confirmationDialog("删除\(removing?["label"].text ?? "")？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let id = removing?["id"]?.string { remove(id) } }
        } message: {
            Text("只删模板库里整理好的这份，你原来的 Word 文件不受影响。")
        }
    }

    func row(_ entry: JSON) -> some View {
        let id = entry["id"]?.string ?? ""
        let usage = entry["usage"]?.int ?? 0
        let sourceRows = entry["sourceRows"]?.int ?? 3000
        let detail = entry["cropped"].isTruthy ? "原来印出来 \(sourceRows) 行，已裁成 60 页" : "正好 60 页"
        return HStack(spacing: Spacing.md) {
            Toggle("", isOn: Binding(get: { entry["enabled"].isTruthy }, set: { setEnabled(id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(entry["enabled"].isTruthy ? "已启用：新项目会分到它" : "已停用：新项目不会分到它，已用它的项目不受影响")
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(entry["label"].text).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                    if !entry["enabled"].isTruthy { TagView(text: "已停用") }
                }
                Text("\(entry["paginationDescription"]?.string ?? detail) · \(entry["sourceName"].text)")
                    .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.md)
            Button(usage == 0 ? "没用过" : "用在 \(usage) 个项目") { showUsage(entry) }
                .buttonStyle(.textAction)
                .disabled(usage == 0)
            Button("打开") { model.open(entry["file"].text) }
                .buttonStyle(.textAction)
                .help("用 WPS（或你默认的 Word 软件）打开整理好的这份，看到的就是交付时的样子")
            Menu {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry["file"].text)]) }
                Divider()
                Button("删除…", role: .destructive) { removing = entry }.disabled(usage > 0)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(usage > 0 ? "用过的模板不能删，可以停用" : "更多")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    func reload() async {
        library = try? await model.core?.codeTemplateLibrary()
        await model.reloadSettings()
    }

    func choose() {
        let files = Panels.chooseFiles("选择代码 Word 模板（可以多选）", extensions: ["docx", "doc"], multiple: true)
        Task { await add(files) }
    }

    func add(_ files: [String]) async {
        let words = files.filter { ["docx", "doc"].contains(Path.extname($0).lowercased().replacingOccurrences(of: ".", with: "")) }
        guard !words.isEmpty, let core = model.core else {
            if !files.isEmpty { model.toast(.warning, "只支持 Word 文件（.docx 或 .doc）") }
            return
        }
        adding = true
        defer { adding = false }
        do { results = try await core.addCodeTemplates(words) } catch { model.toast(.error, messageOf(error)) }
        await reload()
    }

    func droppedFiles(_ providers: [NSItemProvider]) async -> [String] {
        var files: [String] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let path = URL(dataRepresentation: url, relativeTo: nil)?.path {
                files.append(path)
            }
        }
        return files
    }

    func setEnabled(_ id: String, _ value: Bool) {
        Task { _ = await model.perform { try await model.core?.setCodeTemplateEnabled(id, value) }; await reload() }
    }

    func setAssign(_ assign: String, fixed: String) {
        Task { _ = await model.perform { try await model.core?.setCodeTemplateAssignment(assign, fixedId: fixed) }; await reload() }
    }

    func remove(_ id: String) {
        Task { _ = await model.perform("已删除") { try await model.core?.removeCodeTemplate(id) }; await reload() }
    }

    func showUsage(_ entry: JSON) {
        Task {
            let dirs = (try? await model.core?.projectsUsingCodeTemplate(entry["id"]?.string ?? "")) ?? []
            usedBy = (entry["label"].text, dirs.map { Path.basename($0) }.sorted())
        }
    }
}

/// 加模板的结果：每份写明能不能用、裁没裁、不能用的原因。
private struct AddResultsSheet: View {
    let results: [JSON]
    let close: () -> Void

    var body: some View {
        let ok = results.filter { $0["ok"].isTruthy }.count
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(ok == results.count ? "加好了 \(ok) 个模板" : "加好了 \(ok) 个，\(results.count - ok) 个没加")
                .textStyle(Typography.title).foregroundStyle(Palette.text)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(results.indices, id: \.self) { index in
                        let item = results[index]
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Image(systemName: item["ok"].isTruthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item["ok"].isTruthy ? Palette.success : Palette.danger)
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(item["file"].text).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                                Text(describe(item)).textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 460, minHeight: 160, maxHeight: 360)
            HStack { Spacer(); Button("好", action: close).buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        }
        .padding(Spacing.xl)
        .background(Palette.card)
    }

    func describe(_ item: JSON) -> String {
        guard item["ok"].isTruthy else { return item["error"].text }
        let rows = item["sourceRows"]?.int ?? 3000
        let crop = item["cropped"].isTruthy ? "原来印出来 \(rows) 行，已按前 1500 + 后 1500 行裁成 60 页" : "正好 60 页"
        return "\(item["label"].text)：\(item["paginationDescription"]?.string ?? crop)"
    }
}
