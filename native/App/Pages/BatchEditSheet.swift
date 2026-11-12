import StudioCore
import SwiftUI

/// 批量修改：后处理只有这一个入口。选项目（或粘贴名单），写要改什么（照抄退回意见也行），
/// 再勾选不用 AI 的处理。写了要改什么的，先给每个项目整理成修改动作，看过、确认后进批量队列逐个改。
struct BatchEditSheet: View {
    @Environment(AppModel.self) private var model
    let initial: [String]
    let finish: () -> Void
    let cancel: () -> Void

    enum Phase { case edit, organizing, preview, running }
    @State private var phase: Phase = .edit
    @State private var dirs: [String] = []
    @State private var pasteOpen = false
    @State private var pasted = ""
    @State private var missing: [String] = []
    @State private var text = ""
    @State private var codeMode = "none"
    @State private var templateId = ""
    @State private var pdf = false
    @State private var force = "none"
    @State private var results: [JSON] = []
    @State private var included: Set<String> = []
    @State private var organized = 0

    var rows: [ProjectRow] { dirs.compactMap { dir in model.projects.first { $0.dir == dir } } }
    /// 能改的：没提交、不是只读历史项目、没在运行或排队
    var editable: [ProjectRow] {
        rows.filter { !$0.submitted && !$0.historyReadOnly && $0.status != "running" && !(["queued", "paused", "running"].contains($0.queue?["status"]?.string ?? "")) }
    }
    var wantsFeedback: Bool { force == "none" && !text.jsTrimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("批量修改\(dirs.isEmpty ? "" : " \(dirs.count) 个项目")").font(.title2.weight(.semibold))
            switch phase {
            case .edit: editView
            case .organizing: organizingView
            case .preview, .running: previewView
            }
        }
        .padding(22)
        .frame(width: 780, height: 640)
        .onAppear {
            dirs = initial
            pasteOpen = initial.isEmpty
            templateId = model.settings.codeTemplates.enabled.first?.id ?? ""
            if let preset = model.devNameListText {
                pasted = preset
                addPasted()
                model.devNameListText = nil
            }
        }
    }

    // MARK: 第一步：选项目、写要改什么

    var editView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsGroup(title: "项目", trailing: AnyView(Button(pasteOpen ? "收起名单" : "粘贴名单添加…") { pasteOpen.toggle() }.buttonStyle(.borderless))) {
                        VStack(alignment: .leading, spacing: 8) {
                            if rows.isEmpty {
                                Text("还没有项目。在列表里多选后打开这里，或者粘贴一份软件名清单。").foregroundStyle(.secondary)
                            } else {
                                Text(rows.map(\.name).joined(separator: "、")).lineLimit(4).truncationMode(.tail)
                                let skipped = rows.count - editable.count
                                if skipped > 0 { Text("其中 \(skipped) 个已提交、只读或正在运行，会跳过").font(.caption).foregroundStyle(.secondary) }
                            }
                            if pasteOpen {
                                ZStack(alignment: .topLeading) {
                                    if pasted.isEmpty { Text("每行一个软件名，例如：\n示例记账助手V1.0\n示例天气查询V1.0").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8) }
                                    TextEditor(text: $pasted).font(.body).scrollContentBackground(.hidden).frame(height: 90)
                                }
                                .padding(6)
                                .cardBackground(cornerRadius: 8)
                                HStack {
                                    if !missing.isEmpty { Text("没找到：\(missing.prefix(6).joined(separator: "、"))\(missing.count > 6 ? " 等" : "")").font(.caption).foregroundStyle(.orange) }
                                    Spacer()
                                    Button("加入") { addPasted() }.disabled(pasted.jsTrimmed.isEmpty)
                                }
                            }
                        }
                        .padding(12)
                    }
                    SettingsGroup(title: "要改什么", footer: force == "none" ? "照抄退回意见也行。每个项目会先整理成具体的修改（改数据、改图、改文字），你看过确认后才执行。不写就只做下面勾选的处理。" : "选了强制重做时不按这里的意见改。") {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty { Text("例如：违章代码要用真实的；截图里不要出现 2025 年的日期").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8) }
                            TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(height: 90).disabled(force != "none")
                        }
                        .padding(8)
                    }
                    SettingsGroup(title: "同时处理（不用 AI）") {
                        SettingsRow(label: "代码材料") {
                            Picker("", selection: $codeMode) {
                                Text("不动").tag("none")
                                Text("按各自的模板重排").tag("keep")
                                Text("在启用的模板里平均分配").tag("balance")
                                Text("全部换成同一个模板").tag("fixed")
                            }
                            .labelsHidden()
                            .frame(width: 220)
                            if codeMode == "fixed" {
                                Picker("", selection: $templateId) { ForEach(model.settings.codeTemplates.enabled) { Text($0.label).tag($0.id) } }.labelsHidden().frame(width: 120)
                            }
                        }
                        SettingsRow(label: "重新导出 PDF", hint: "换了字体后用；会重新生成的项目出包时自带新 PDF，不重复导出") {
                            Toggle("", isOn: $pdf).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    SettingsGroup(title: "强制重做") {
                        Picker("", selection: $force) {
                            Text("不强制").tag("none")
                            Text("只重写文字").tag("rewrite")
                            Text("整个重新生成").tag("regenerate")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(12)
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(wantsFeedback ? "下一步：整理修改意见" : "下一步") { next() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(editable.isEmpty || (!wantsFeedback && codeMode == "none" && !pdf && force == "none") || (codeMode == "fixed" && templateId.isEmpty))
            }
        }
    }

    /// 按名字找项目：先按完整名字（忽略空格和大小写），找不到再按包含这几个字、只找到一个时算
    func addPasted() {
        func key(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        var notFound: [String] = []
        for raw in Rx.split(#"\r?\n"#, pasted) {
            let name = (Rx.split("[,，\\t]", raw.jsTrimmed).first ?? "").jsTrimmed
            guard !name.isEmpty else { continue }
            let wanted = key(name)
            let exact = model.projects.filter { key($0.name) == wanted }
            let loose = model.projects.filter { key($0.name).contains(wanted) || wanted.contains(key($0.name)) }
            guard let row = exact.first ?? (loose.count == 1 ? loose[0] : nil) else { notFound.append(name); continue }
            if !dirs.contains(row.dir) { dirs.append(row.dir) }
        }
        missing = notFound
        if notFound.isEmpty { pasted = "" }
    }

    func next() {
        guard wantsFeedback, let core = model.core else { phase = .preview; return }
        phase = .organizing
        organized = 0
        results = []
        let targets = editable.map(\.dir)
        let requirement = text.jsTrimmed
        Task {
            // 每个项目一次大模型请求，同时整理 3 个
            var collected: [JSON] = []
            await withTaskGroup(of: JSON.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<min(3, targets.count) {
                    if let dir = iterator.next() { group.addTask { await core.organizeBatchEdit(dir, text: requirement) } }
                }
                for await result in group {
                    collected.append(result)
                    organized += 1
                    if let dir = iterator.next() { group.addTask { await core.organizeBatchEdit(dir, text: requirement) } }
                }
            }
            results = targets.compactMap { dir in collected.first { $0["dir"]?.string == dir } }
            included = Set(results.filter { $0["ok"].isTruthy && !($0["plan"]?["actions"]).items.isEmpty }.compactMap { $0["dir"]?.string })
            phase = .preview
        }
    }

    var organizingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("正在整理修改意见 \(organized) / \(editable.count)").font(.headline)
            ProgressView(value: Double(organized), total: Double(max(editable.count, 1)))
            Text("每个项目调用一次大模型，同时整理 3 个。").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: 第二步：看整理结果，确认执行

    var previewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(results.indices, id: \.self) { index in resultRow(results[index]) }
                    Banner(.info, "将会：\(summaryLines.joined(separator: "；"))。要调用 AI 的进批量队列，可以暂停、继续。")
                }
            }
            HStack {
                if !results.isEmpty { Button("返回修改") { discard(); phase = .edit } }
                Spacer()
                Button("取消") { discard(); cancel() }.keyboardShortcut(.cancelAction)
                Button("开始执行") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(phase == .running || summaryLines.isEmpty)
            }
        }
    }

    @ViewBuilder
    func resultRow(_ item: JSON) -> some View {
        let dir = item["dir"].text
        let actions = (item["plan"]?["actions"]).items
        HStack(alignment: .top, spacing: 10) {
            if item["ok"].isTruthy, !actions.isEmpty {
                Toggle("", isOn: Binding(get: { included.contains(dir) }, set: { if $0 { included.insert(dir) } else { included.remove(dir) } })).toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item["name"].text).fontWeight(.semibold)
                if !item["ok"].isTruthy {
                    Text("跳过：\(item["reason"].text)").font(.callout).foregroundStyle(.secondary)
                } else if actions.isEmpty {
                    Text("没整理出能直接执行的修改，这条意见留在项目的修改意见里").font(.callout).foregroundStyle(.secondary)
                } else {
                    let summary = (item["plan"]?["summary"]).text
                    if !summary.isEmpty { Text(summary).font(.callout) }
                    Text(actions.map { "\(actionLabel($0["type"].text))：\($0["targetLabel"].text)" }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    let questions = (item["plan"]?["questions"]).items.count
                    if questions > 0 { Text("另有 \(questions) 条没判断出位置，留在项目的修改意见里").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 10)
    }

    func actionLabel(_ type: String) -> String {
        ["data": "改数据", "image": "改图", "text": "改文字", "overview": "改封面介绍", "design": "改设计说明", "replan": "重新规划"][type] ?? type
    }

    var codeDirs: [String] { codeMode == "none" ? [] : editable.filter(\.hasBundle).map(\.dir) }
    /// 会重新出包的项目（出包时自带新 PDF）
    var rebuilt: Set<String> { force != "none" ? Set(editable.map(\.dir)) : included }
    var pdfDirs: [String] { pdf ? editable.filter { $0.hasBundle && !rebuilt.contains($0.dir) }.map(\.dir) : [] }

    var summaryLines: [String] {
        var lines: [String] = []
        if !codeDirs.isEmpty { lines.append("代码材料 \(codeDirs.count) 个（\(["keep": "按各自的模板重排", "balance": "平均分配模板", "fixed": "换成同一个模板"][codeMode] ?? "")）") }
        switch force {
        case "rewrite": lines.append("只重写文字 \(editable.count) 个")
        case "regenerate": lines.append("整个重新生成 \(editable.count) 个（旧文件先归档）")
        default: if !included.isEmpty { lines.append("按修改意见改 \(included.count) 个") }
        }
        if !pdfDirs.isEmpty { lines.append("重新导出 PDF \(pdfDirs.count) 个") }
        return lines
    }

    /// 撤掉刚加上的修改意见（取消、返回修改、没勾选的项目）
    func discard(_ only: Set<String>? = nil) {
        guard let core = model.core else { return }
        let targets = results.filter { $0["ok"].isTruthy && (only?.contains($0["dir"].text) ?? true) }
        results = []
        Task { for item in targets { await core.discardBatchEdit(item["dir"].text, feedbackId: item["feedbackId"].text) } }
    }

    func run() {
        guard let core = model.core else { return }
        phase = .running
        let code = codeDirs, pdfTargets = pdfDirs, chosen = included, targets = editable.map(\.dir)
        let skippedFeedback = Set(results.filter { $0["ok"].isTruthy }.map { $0["dir"].text }).subtracting(chosen)
        discard(skippedFeedback)
        Task {
            var parts: [String] = []
            var problems: [String] = []
            // 1. 不用 AI 的先做完，再进队列（正在排队的项目更新代码材料会被跳过）
            if !code.isEmpty {
                let result = await core.applyCodeTemplates(code, mode: codeMode, templateId: codeMode == "fixed" ? templateId : nil)
                parts.append("代码材料更新 \(result["done"].items.count) 个")
                problems += (result["failed"].items + result["skipped"].items).map(\.jsString)
            }
            // 2. 要调用 AI 的进批量队列
            switch force {
            case "rewrite":
                await core.batch.enqueue(targets, name: "批量修改：只重写文字", mode: "rewrite")
                parts.append("只重写文字 \(targets.count) 个")
            case "regenerate":
                var started = 0
                for dir in targets {
                    do { try await core.regenerateProject(dir); started += 1 } catch { problems.append("\(Path.basename(dir))：\(messageOf(error))") }
                }
                parts.append("整个重新生成 \(started) 个")
            default:
                if !chosen.isEmpty {
                    await core.batch.enqueue(targets.filter(chosen.contains), name: "批量修改", mode: "feedback")
                    parts.append("按修改意见改 \(chosen.count) 个")
                }
            }
            // 3. 重新导出 PDF
            if !pdfTargets.isEmpty {
                let result = await core.reexportPdfs(pdfTargets)
                parts.append("重新导出 PDF \(result["done"].items.count) 个")
                problems += result["failed"].items.map(\.jsString)
            }
            await model.reloadProjects()
            if problems.isEmpty { model.toast(.success, "已开始：" + parts.joined(separator: "，")) }
            else { model.alert = AlertItem(title: "批量修改：" + parts.joined(separator: "，"), message: problems.joined(separator: "\n")) }
            finish()
        }
    }
}
