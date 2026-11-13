import StudioCore
import SwiftUI

/// 编辑：左侧选择截图，右侧查看大图并修改说明。
/// - 文字直接改，自动保存，每处都能从「历史」换回以前的文字；
/// - 每一行下面写「要怎么改」，点「改图」或「只改文字」，不用先攒清单再整理；
/// - 截图可以重新生成、换回以前的截图、换备选图；封面介绍和设计说明同样直接改。
struct EditorTab: View {
    let data: ProjectData
    let running: Bool
    let onChanged: () -> Void
    @Environment(AppModel.self) var model

    struct Section: Equatable {
        var title: String
        var text: String
    }

    // 文字：输入框里的内容和最近一次读到 / 保存的内容；不同就是还没保存的修改
    @State var overview = ""
    @State var titles: [String: String] = [:]
    @State var texts: [String: String] = [:]
    @State var sections: [Section] = []
    @State var baseOverview = ""
    @State var baseTitles: [String: String] = [:]
    @State var baseTexts: [String: String] = [:]
    @State var baseSections: [Section] = []
    @State var loadedKey = ""
    @State var saveState: SaveState = .idle
    @State var rewrite: (ids: [String], label: String)?
    // 每一行的「要怎么改」
    @State var changeRequests: [String: String] = [:]
    // 截图的弹窗
    @State var preview: ScreenItem?
    @State var promptEdit: ScreenItem?
    @State var alternates: ScreenItem?
    @State var history: ScreenItem?
    @State var regenerate: ScreenItem?

    enum SaveState: Equatable {
        case idle, saving, saved(Date), failed(String)
    }

    var floor: Int { model.settings.pipeline.featureTextFloor }
    var contentScreens: [JSON] { data.content?["screens"].items ?? [] }
    var editable: Bool { !data.readOnly && !running }

    var contentKey: String {
        guard let content = data.content else { return "" }
        return Self.key(for: content)
    }

    private static func key(for content: JSON) -> String {
        JSON.obj([
            "o": content["cover"]?["overview"] ?? .null,
            "s": .array(content["screens"].items.map { .array([$0["id"] ?? .null, $0["title"] ?? .null, $0["text"] ?? .null]) }),
            "d": content["design"]?["sections"] ?? .null,
        ]).serialized()
    }

    var editsKey: String {
        JSON.obj([
            "o": .string(overview),
            "t": JSON(titles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }),
            "x": JSON(texts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }),
            "d": JSON(sections.map { "\($0.title)=\($0.text)" }),
        ]).serialized()
    }

    @State var selectedScreen = ""
    @State private var detailReady = false

    /// 首次创建文字控件时就带入文案，避免出现后再填充空状态触发整页布局。
    init(data: ProjectData, running: Bool, onChanged: @escaping () -> Void) {
        self.data = data
        self.running = running
        self.onChanged = onChanged
        guard let content = data.content else { return }
        let overview = content["cover"]?["overview"].text ?? ""
        let screens = content["screens"].items
        let titles = Dictionary(screens.map { ($0["id"]?.jsString ?? "", $0["title"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let texts = Dictionary(screens.map { ($0["id"]?.jsString ?? "", $0["text"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let sections = (content["design"]?["sections"].items ?? []).map { Section(title: $0["title"].text, text: $0["text"].text) }
        // 草稿和已保存基线同时初始化；后续同步仍保留未保存的修改。
        _overview = State(initialValue: overview)
        _baseOverview = State(initialValue: overview)
        _titles = State(initialValue: titles)
        _baseTitles = State(initialValue: titles)
        _texts = State(initialValue: texts)
        _baseTexts = State(initialValue: texts)
        _sections = State(initialValue: sections)
        _baseSections = State(initialValue: sections)
        _loadedKey = State(initialValue: Self.key(for: content))
    }

    var body: some View {
        Group {
            if data.screens.isEmpty && data.content == nil {
                EmptyHint(title: data.readOnly ? "这个旧项目没有截图源文件" : "规划完成后会在这里显示截图和说明", systemImage: "rectangle.split.2x1")
                    .frame(minHeight: 300)
            } else {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    statusLine
                    AdaptiveColumns(breakpoint: Metrics.sidebarWidth + Metrics.editorImageWidth + Spacing.xl, leadingWidth: Metrics.sidebarWidth) {
                        screenshotList.frame(width: Metrics.sidebarWidth)
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            if !detailReady {
                                Text("正在载入编辑内容…").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: Metrics.gridShotHeight)
                            } else if selectedScreen == "overview" { coverEditor }
                            else if selectedScreen == "design" { designEditor }
                            else if let index = data.screens.firstIndex(where: { $0.id == selectedScreen }) ?? data.screens.indices.first {
                                let screen = data.screens[index]
                                AdaptiveColumns(breakpoint: Metrics.editorImageWidth * 2) {
                                    screenColumn(screen)
                                    textColumn(index, screen)
                                }
                                if !data.readOnly { changeBar(index, screen) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("trialEditorScreen"))) { note in
            guard AppModel.isTrial, let value = note.object as? String, let index = Int(value), data.screens.indices.contains(index) else { return }
            selectedScreen = data.screens[index].id
        }
        .task {
            // 先显示截图导航，再创建大图和文字控件；中途离开时取消后续挂载。
            guard !detailReady else { return }
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled { detailReady = true }
        }
        .onAppear { syncFromContent() }
        .onChange(of: contentKey) { _, _ in syncFromContent() }
        // 停止输入 0.8 秒后自动保存；继续输入会重新计时
        .task(id: editsKey) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { await autosave() }
        }
        .onDisappear(perform: flush)
        .background {
            // ⌘S：马上保存（平时不用按）
            Button("") { Task { await autosave() } }.keyboardShortcut("s").hidden()
        }
        .sheet(item: $preview) { screen in ScreenPreviewSheet(screen: screen) }
        .sheet(item: $promptEdit) { screen in
            PromptSheet(screen: screen) { text in
                Task {
                    let ok = await model.perform("提示词已保存，下次运行时会重新生成这一屏") { try await model.core?.pipeline.savePrompt(data.dir, screen.id, text) }
                    if ok { promptEdit = nil }
                    onChanged()
                }
            }
        }
        .sheet(item: $alternates) { screen in
            AlternatesSheet(screen: screen) { file in
                Task {
                    let ok = await model.perform("已替换，旧图已存进「以前的截图」") { try await model.core?.pipeline.useAlternate(data.dir, screen.id, file) }
                    if ok { alternates = nil }
                    onChanged()
                }
            }
        }
        .sheet(item: $history) { screen in
            ScreenHistorySheet(screen: screen) { file in
                Task {
                    let ok = await model.perform("已换回，刚才那张也存进了「以前的截图」") { try await model.core?.pipeline.restoreScreen(data.dir, screen.id, file) }
                    if ok { history = nil }
                    onChanged()
                }
            }
        }
        .confirmationDialog(regenerate.map { "重新生成 \($0.id)？" } ?? "", isPresented: Binding(get: { regenerate != nil }, set: { if !$0 { regenerate = nil } }), titleVisibility: .visible) {
            Button("重新生成") {
                guard let screen = regenerate else { return }
                Task { await model.perform { _ = try model.core?.pipeline.regenerateScreen(data.dir, screen.id) } }
            }
        } message: {
            Text("会花一张图的费用，按原来的要求再生成一次。想改什么的话，在这一行下面写「要怎么改」再点「改图」。现在这张会存进「以前的截图」。")
        }
        .confirmationDialog(rewrite.map { "让大模型重写\($0.label)？" } ?? "", isPresented: Binding(get: { rewrite != nil }, set: { if !$0 { rewrite = nil } }), titleVisibility: .visible) {
            Button("重写") {
                guard let target = rewrite else { return }
                Task {
                    await autosave()
                    await model.perform { _ = try await model.core?.pipeline.rewriteContent(data.dir, target.ids) }
                }
            }
        } message: {
            Text("会覆盖现在的文字（包括你改过的部分）。现在的文字会存进「历史」，不满意可以换回来。想按要求改，在这一行下面写「要怎么改」再点「只改文字」。")
        }
    }

    func syncFromContent() {
        guard let content = data.content, contentKey != loadedKey else { return }
        loadedKey = contentKey
        let serverOverview = content["cover"]?["overview"].text ?? ""
        let serverTitles = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["title"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let serverTexts = Dictionary(contentScreens.map { ($0["id"]?.jsString ?? "", $0["text"]?.jsString ?? "") }, uniquingKeysWith: { first, _ in first })
        let serverSections = (content["design"]?["sections"].items ?? []).map { Section(title: $0["title"].text, text: $0["text"].text) }
        // 输入框没改过的跟着磁盘更新；改过还没保存的保留，等自动保存
        if overview == baseOverview { overview = serverOverview }
        for (id, value) in serverTitles where titles[id] == baseTitles[id] { titles[id] = value }
        for (id, value) in serverTexts where texts[id] == baseTexts[id] { texts[id] = value }
        if sections == baseSections { sections = serverSections }
        baseOverview = serverOverview
        baseTitles = serverTitles
        baseTexts = serverTexts
        baseSections = serverSections
    }

    struct Pending {
        var overview: String?
        var patches: [JSON]
        var design: [JSON]?
    }

    func pending() -> Pending? {
        guard data.content != nil, !data.readOnly else { return nil }
        let changedOverview = overview != baseOverview ? overview : nil
        let patches: [JSON] = contentScreens.compactMap { screen in
            let id = screen["id"]?.jsString ?? ""
            guard titles[id] != baseTitles[id] || texts[id] != baseTexts[id] else { return nil }
            return .obj(["id": .string(id), "title": .string(titles[id] ?? ""), "text": .string(texts[id] ?? "")])
        }
        let design: [JSON]? = sections != baseSections ? sections.map { .obj(["title": .string($0.title), "text": .string($0.text)]) } : nil
        return changedOverview == nil && patches.isEmpty && design == nil ? nil : Pending(overview: changedOverview, patches: patches, design: design)
    }

    func autosave() async {
        guard !running, let core = model.core, let change = pending() else { return }
        let savedSections = sections
        saveState = .saving
        do {
            try await core.pipeline.saveContent(data.dir, overview: change.overview, screens: change.patches, design: change.design)
            if let saved = change.overview { baseOverview = saved }
            for patch in change.patches {
                let id = patch["id"]?.jsString ?? ""
                baseTitles[id] = patch["title"]?.jsString
                baseTexts[id] = patch["text"]?.jsString
            }
            if change.design != nil { baseSections = savedSections }
            saveState = .saved(Date())
            onChanged()
        } catch {
            saveState = .failed(messageOf(error))
        }
    }

    /// 离开时把没保存的修改存掉（不等计时）
    func flush() {
        guard !running, let core = model.core, let change = pending() else { return }
        let dir = data.dir
        Task {
            do { try await core.pipeline.saveContent(dir, overview: change.overview, screens: change.patches, design: change.design) }
            catch { model.toast(.error, "文字没有保存：\(messageOf(error))") }
        }
    }
}
