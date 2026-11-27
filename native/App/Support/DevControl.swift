import AppKit
import StudioCore
import SwiftUI

/// 开发自检：设置 MS_DEV_CONTROL=<文件> 时，App 每 0.4 秒读一次这个文件，按里面的指令切换页面，
/// 配合截图脚本逐页检查界面（仅在开发/试用自检时使用）。
/// 指令一行一个：section=projects|new|...、modelsTab=llm、settingsTab=pdf|cleanup、open=<项目路径>、projectTab=overview|plan|editor|delivery、
/// feedback=open|close、newMode=single|batch、appearance=dark|light、size=1440x920、select=<路径>|none、back、hold=1|0、
/// timeFilter、query、status、presentation=list|grid、queueDetails=1|0、cleanup=select:tier1|select:tier2|select:all|select:none|rescan|run（仅试用版生效）、
/// codebatch、namelist、scroll=1|0、reload、listSnapshot、measureAll=1|0、stress、probe、trialStep|trialEdit|trialExport|trialGatePending|editorScreen|screenshot（仅试用版生效）、activate、minimize、close
@MainActor
final class DevControl {
    static let shared = DevControl()
    private var lastText = ""
    private var timer: Timer?

    func start(_ model: AppModel) {
        guard let file = ProcessInfo.processInfo.environment["MS_DEV_CONTROL"], timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(file, model) }
        }
    }

    private func poll(_ file: String, _ model: AppModel) {
        guard let text = FS.readTextIfExists(file), text != lastText else { return }
        lastText = text
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.jsTrimmed, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].jsTrimmed : ""
            apply(key, value, model)
        }
    }

    private func apply(_ key: String, _ value: String, _ model: AppModel) {
        switch key {
        case "section":
            model.newProjectPresented = false
            if value == "new" { model.showNewProject() }
            else if let item = SidebarItem(rawValue: value) { model.go(item) }
        case "modelsTab": model.modelsTab = value
        case "settingsTab": model.settingsTab = value
        case "open": model.openProject(value)
        case "trialStep":
            // 试用验收专用：明确限定到单个本机步骤，不会继续执行后续 AI 步骤。
            guard AppModel.isTrial, !model.trialMeasure, [PipelineStepName.receipt.rawValue, PipelineStepName.build.rawValue].contains(value),
                  let core = model.core, let dir = model.projectPath.last,
                  Path.isInside(TrialData.canonical(Path.join(model.dataDir, "workspace")), TrialData.canonical(dir)),
                  model.projects.contains(where: { $0.dir == dir }) else { return }
            Task {
                let result = await core.run(dir, RunOptions(from: value, until: value, force: [value])).value
                try? FS.writeJSONAtomic(Path.join(model.dataDir, "trial-step-result.json"),
                                       .obj(["step": .string(value), "status": .string(result.status), "error": result.error.map(JSON.string) ?? .null]))
            }
        case "trialEdit", "trialExport", "trialGatePending":
            guard AppModel.isTrial, !model.trialMeasure, let core = model.core, let dir = model.projectPath.last,
                  Path.isInside(TrialData.canonical(Path.join(model.dataDir, "workspace")), TrialData.canonical(dir)) else { return }
            Task {
                do {
                    if key == "trialEdit" {
                        try await core.pipeline.saveContent(dir, overview: value, screens: [])
                    } else if key == "trialExport" {
                        let result = try await core.exportBundles([dir], targetDir: value)
                        try FS.writeJSONAtomic(Path.join(model.dataDir, "trial-export-result.json"), result)
                    } else {
                        // 等效于换图后失效的验收状态，不执行任何模型步骤。
                        _ = try await core.projectStore.update(dir) { raw in
                            var typed = ProjectState(raw)
                            var gate = typed[step: .gate] ?? StepState(.emptyObject)
                            gate.status = .pending
                            typed[step: .gate] = gate
                            typed.status = .idle
                            raw = typed.raw
                        }
                        model.bump(dir)
                    }
                } catch { model.toast(.error, messageOf(error)) }
            }
        case "back": model.projectPath = []
        // 试用版逐屏定位：从零开始的序号；仅改变选择，不执行修改或模型步骤。
        case "editorScreen":
            guard AppModel.isTrial else { return }
            NotificationCenter.default.post(name: Notification.Name("trialEditorScreen"), object: value)
        case "projectTab": model.devProjectTab = ProjectTab(name: value)
        case "feedback":
            if value == "open" { model.batchModification = BatchModificationRequest(dirs: model.projectPath.last.map { [$0] } ?? []) }
            else { model.batchModification = nil }
        case "newMode":
            guard ["single", "batch"].contains(value) else { return }
            model.devNewMode = value
            model.showNewProject()
        case "select": model.devSelection = value == "none" ? [] : Set(value.split(separator: "|").map(String.init))
        case "appearance":
            NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
        case "size":
            let numbers = value.split(separator: "x").compactMap { Double($0) }
            if numbers.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                var frame = window.frame
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                window.setFrame(frame, display: true, animate: false)
            }
        case "hold":
            model.devHoldBackground = value == "1"
            if !model.devHoldBackground { model.quitIfIdleInBackground() }
        case "timeFilter": model.devTimeFilter = value + "#" + String(Date().timeIntervalSince1970)
        case "minimize":
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.miniaturize(nil)
        case "close":
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.performClose(nil)
        case "cleanup": model.devCleanup = value + "#" + String(Date().timeIntervalSince1970)
        case "codebatch": model.devCodeBatch = value + "#" + String(Date().timeIntervalSince1970)
        case "namelist": model.devNameListText = value.replacingOccurrences(of: "|", with: "\n")
        case "query": model.listQuery = value
        case "status":
            if let group = ProjectGroup(rawValue: value) ?? ProjectGroup.allCases.first(where: { $0.title == value }) { model.listStatus = group.rawValue }
        case "queueDetails": model.devQueueExpanded = value == "1"
        case "measureAll":
            if model.trialMeasure { model.listOnly = value == "1" ? Set(model.projects.map(\.dir)) : nil }
        case "presentation": if ["list", "grid"].contains(value) { model.devProjectPresentation = value }
        case "scroll": startScroll(value == "1")
        case "reload": Task { await model.reloadProjects() }
        case "listSnapshot":
            guard AppModel.isTrial else { return }
            try? FS.writeJSONAtomic(value, .array(model.projects.map(\.json)))
        case "stress": startStress(Int(value) ?? 0, model)
        case "probe": value == "stop" ? stopProbe() : startProbe(value)
        case "activate":
            NSApp.windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        case "screenshot":
            guard AppModel.isTrial, !value.isEmpty,
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: value))
                }
            }
        default: break
        }
    }

    // MARK: 卡顿测量（只在开发自检时用）
    // stress=<每秒几条>：模拟批量运行，不断发进度、项目、截图事件（不调用 AI、不改文件）；stress=0 停。
    // probe=<结果文件>：每 16 毫秒问一次界面线程，记下它晚了多久才回应；probe=stop 写出统计。

    // scroll=1|0：试用版中以固定速度往返滚动真实表格，不改变选择或排序。
    private var scrollTimer: Timer?
    private var scrollDirection: CGFloat = 1

    private func startScroll(_ enabled: Bool) {
        scrollTimer?.invalidate()
        scrollTimer = nil
        guard AppModel.isTrial, enabled else { return }
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                func findTable(_ view: NSView) -> NSTableView? {
                    if let table = view as? NSTableView { return table }
                    return view.subviews.lazy.compactMap { findTable($0) }.first
                }
                func findGridScroll(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView, scroll.identifier?.rawValue == "project-grid-scroll" { return scroll }
                    return view.subviews.lazy.compactMap { findGridScroll($0) }.first
                }
                guard let content = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView else { return }
                let grid = UserDefaults.standard.string(forKey: "projects.presentation") == "grid"
                guard let scroll = grid ? findGridScroll(content) : findTable(content)?.enclosingScrollView,
                      let document = scroll.documentView else { return }
                let clip = scroll.contentView
                let limit = max(0, document.bounds.height - clip.bounds.height)
                let next = min(limit, max(0, clip.bounds.minY + self.scrollDirection * 12))
                if next >= limit { self.scrollDirection = -1 }
                if next <= 0 { self.scrollDirection = 1 }
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    private var stressTimer: Timer?
    private var stressCount = 0

    private func startStress(_ perSecond: Int, _ model: AppModel) {
        stressTimer?.invalidate()
        stressTimer = nil
        guard perSecond > 0 else { return }
        stressTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(perSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stressCount += 1
                let dirs = model.projects.prefix(12).map(\.dir) + model.projectPath
                guard let dir = dirs.randomElement() else { return }
                let progress: JSON = .obj(["step": .string(PipelineStepName.images.rawValue), "started": .number(nowMs() - 60_000), "stepStarted": .number(nowMs() - 20_000),
                                           "screens": .obj(["finished": .number(Double(self.stressCount % 7)), "total": 7]), "detail": .string("模拟进度 \(self.stressCount)")])
                model.handle(.obj(["type": "progress", "projectDir": .string(dir), "progress": progress]))
                if self.stressCount % 3 == 0 { model.handle(.obj(["type": "image", "projectDir": .string(dir), "kind": "attempt"])) }
                if self.stressCount % 5 == 0 { model.handle(.obj(["type": "project", "projectDir": .string(dir)])) }
            }
        }
    }

    private let probeState = Locked<(file: String, lags: [Double], timer: DispatchSourceTimer?)>(("", [], nil))

    private var probeActivity: NSObjectProtocol?

    private func startProbe(_ file: String) {
        stopProbe()
        probeActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "列表延迟采样")
        let timer = Self.makeProbeTimer(probeState)
        probeState.withLock { $0 = (file, [], timer) }
        timer.resume()
    }

    /// 计时器在后台线程跑，不能带界面线程的隔离（否则运行时检查会直接崩）
    private nonisolated static func makeProbeTimer(_ state: Locked<(file: String, lags: [Double], timer: DispatchSourceTimer?)>) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { @Sendable in
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { @Sendable in
                let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                state.withLock { $0.lags.append(lag) }
            }
        }
        return timer
    }

    private func stopProbe() {
        if let probeActivity { ProcessInfo.processInfo.endActivity(probeActivity) }
        probeActivity = nil
        let (file, lags, timer) = probeState.withLock { current -> (String, [Double], DispatchSourceTimer?) in
            let snapshot = current
            current = ("", [], nil)
            return snapshot
        }
        timer?.cancel()
        guard !file.isEmpty, !lags.isEmpty else { return }
        let sorted = lags.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let report: JSON = .obj([
            "samples": .number(Double(lags.count)), "avgMs": .number((lags.reduce(0, +) / Double(lags.count) * 10).rounded() / 10),
            "p95Ms": .number(pct(0.95).rounded()), "maxMs": .number(sorted.last!.rounded()),
            "over100ms": .number(Double(lags.filter { $0 > 100 }.count)), "over250ms": .number(Double(lags.filter { $0 > 250 }.count)),
            "over1000ms": .number(Double(lags.filter { $0 > 1000 }.count)),
        ])
        try? FS.writeJSONAtomic(file, report)
    }
}
