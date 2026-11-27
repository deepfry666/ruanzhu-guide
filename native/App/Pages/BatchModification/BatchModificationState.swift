import StudioCore
import SwiftUI

struct BatchModificationRequest: Identifiable {
    let id = UUID()
    let dirs: [String]
    var finished: () -> Void = {}
}

struct ModificationPreview: Identifiable {
    let dir: String
    var id: String { dir }
    let data: ProjectData
    let originalPlan: JSON
    var actions: [JSON]
    var checked: [Bool]
    var questions: [JSON]
    var questionTargets: [String]
    var error: String?
    var chosen: [JSON] { actions.enumerated().filter { checked[$0.offset] }.map(\.element) }

    init(data: ProjectData, plan: JSON = .emptyObject, error: String? = nil) {
        dir = data.dir
        self.data = data
        originalPlan = plan
        actions = plan["actions"].items
        checked = Array(repeating: true, count: actions.count)
        questions = plan["questions"].items
        questionTargets = Array(repeating: "", count: questions.count)
        self.error = error
    }
}

@MainActor @Observable
final class BatchModificationState {
    enum Step { case write, preview, confirm }
    let model: AppModel
    var dirs: [String]
    var projects: [String: ProjectData] = [:]
    var errors: [String: String] = [:]
    var step: Step = .write
    var busy = false
    var progress = ""
    var note = ""
    var editingNotes: [String: String] = [:]
    var completedCode: [String: String] = [:]
    var errorMessage: String?
    var hasDraft: Bool { !note.jsTrimmed.isEmpty || !editingNotes.isEmpty }
    var target = ""
    var codeMode = "none"
    var templateId: String
    var force = "none"
    var previews: [ModificationPreview] = []
    var analysisConsent = false
    var requestedAnalysis: [String] = []
    var missing: [String] = []

    init(model: AppModel, dirs: [String]) {
        self.model = model
        self.dirs = Array(NSOrderedSet(array: dirs)) as? [String] ?? dirs
        templateId = model.settings.codeTemplates.enabled.first?.id ?? ""
    }

    func pending(_ data: ProjectData) -> [FeedbackItem] {
        data.pendingFeedbackItems
    }
    func reason(_ data: ProjectData) -> String? {
        if data.readOnly { return "已提交或只读" }
        if data.runningFlag || data.status == .running || model.core?.pipeline.isRunning(data.dir) == true { return "正在运行" }
        let busyQueue: Set<QueueStatus> = [.queued, .paused, .running]
        if model.core?.batch.list().items.map(BatchQueueItem.init).contains(where: { item in
            item.projectDir == data.dir && item.status.map { busyQueue.contains($0) } == true
        }) == true { return "正在运行或排队" }
        return nil
    }
    var editable: [ProjectData] { dirs.compactMap { projects[$0] }.filter { reason($0) == nil } }
    var analysisTargets: [ProjectData] { editable.filter { $0.plan != nil && !pending($0).isEmpty } }
    var canNext: Bool {
        !busy && !hasDraft && !editable.isEmpty &&
        (force != "none" || codeMode != "none" || !analysisTargets.isEmpty) &&
        (codeMode != "fixed" || !templateId.isEmpty)
    }
    func codeKey(_ dir: String) -> String { "\(codeMode)|\(templateId)|\(dir)" }
    var codeDirs: [String] {
        codeMode == "none" ? [] : editable.filter { data in
            model.projects.first { $0.dir == data.dir }?.hasBundle == true && completedCode[data.dir] != codeKey(data.dir)
        }.map(\.dir)
    }
    var chosen: [ModificationPreview] { previews.filter { $0.error == nil && !$0.chosen.isEmpty } }
    var hasWork: Bool { !codeDirs.isEmpty || (force != "none" && !editable.isEmpty) || !chosen.isEmpty }

    func refresh() async {
        guard let core = model.core else { return }
        for dir in dirs {
            do { projects[dir] = ProjectData(json: try await core.getProject(dir)); errors[dir] = nil }
            catch { projects[dir] = nil; errors[dir] = messageOf(error) }
        }
    }

    func addNames(_ pasted: String, remove: Bool = false) async {
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        missing = []
        for raw in Rx.split(#"\r?\n"#, pasted) {
            let name = (Rx.split("[,，\\t]", raw.jsTrimmed).first ?? "").jsTrimmed
            guard !name.isEmpty else { continue }
            let exact = model.projects.filter { key($0.name) == key(name) }
            let loose = model.projects.filter { key($0.name).contains(key(name)) || key(name).contains(key($0.name)) }
            let matches = exact.isEmpty ? loose : exact
            guard matches.count == 1, let row = matches.first else { missing.append(name); continue }
            if remove { dirs.removeAll { $0 == row.dir } }
            else if !dirs.contains(row.dir) { dirs.append(row.dir) }
        }
        target = ""
        await refresh()
    }

    func addNote() async {
        guard !busy, let core = model.core, !note.jsTrimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        let text = note.jsTrimmed, selectedTarget = dirs.count == 1 && !target.isEmpty ? target : nil
        let targets = editable.filter { $0.plan != nil }
        var failed: [String] = []
        for data in targets {
            do { _ = try await core.pipeline.addFeedback(data.dir, text, target: selectedTarget); model.bump(data.dir) }
            catch { failed.append("\(data.name)：\(messageOf(error))") }
        }
        // 部分成功后清空输入，避免重按时给成功项目添加重复意见。
        if !targets.isEmpty { note = "" }
        await refresh()
        if !failed.isEmpty { errorMessage = "部分意见未保存：\n" + failed.joined(separator: "\n") + "\n请对未保存的项目重新添加。原意见：" + text }
    }

    func next() {
        guard canNext else { return }
        if force == "none", !analysisTargets.isEmpty { requestedAnalysis = analysisTargets.map(\.dir); analysisConsent = true }
        else { previews = []; step = .preview }
    }

    func analyze() async {
        guard !busy, let core = model.core else { return }
        busy = true
        defer { busy = false; progress = "" }
        await refresh()
        let targets = analysisTargets.filter { requestedAnalysis.contains($0.dir) }
        previews = []
        for (index, data) in targets.enumerated() {
            progress = "正在整理意见 \(index + 1) / \(targets.count)"
            do {
                let plan: JSON
                if dirs.count == 1 { plan = try await core.pipeline.analyzeFeedback(data.dir) }
                else {
                    let result = await core.organizeBatchEdit(data.dir)
                    guard result["ok"].isTruthy else { throw StudioError(result["reason"].text) }
                    plan = result["plan"] ?? .emptyObject
                }
                previews.append(ModificationPreview(data: data, plan: plan))
            } catch { previews.append(ModificationPreview(data: data, error: messageOf(error))) }
            model.bump(data.dir)
        }
        await refresh()
        step = .preview
    }
}
