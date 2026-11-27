import Foundation

let IMPORT_SKIP_DIRS: Set<String> = ["node_modules", "docs", "tools", "tmp", "archive", "尺寸兼容测试"]

/// 扫描工作区里的历史项目（只读）。分级：
/// - ready：文案、截图齐全，审查回执和当前截图一致，可以直接编辑
/// - needs-gate：有文案和截图，但回执缺失或对不上，需要重新验收
/// - readonly：只有交付包，没有 content.json，只能查看
public func scanWorkspace(_ workspaceDir: String, isManaged: (String) -> Bool = { _ in false }) throws -> [JSON] {
    guard let entries = FS.list(workspaceDir) else { throw StudioError("工作区不存在：\(workspaceDir)") }
    var results: [JSON] = []
    for name in entries {
        let dir = Path.join(workspaceDir, name)
        guard FS.isDirectory(dir), !name.hasPrefix("."), !IMPORT_SKIP_DIRS.contains(name) else { continue }
        guard var info = inspectProject(dir) else { continue }
        info["managed"] = .bool(isManaged(dir))
        results.append(info)
    }
    return results.sorted { ($0["mtime"]?.number ?? 0) > ($1["mtime"]?.number ?? 0) }
}

public func inspectProject(_ dir: String) -> JSON? {
    let paths = projectPaths(dir)
    let content = FS.readJSONQuiet(paths.content)
    let manifest = FS.readJSONQuiet(paths.manifest)
    let softwareName = (content?["softwareName"].truthyValue ?? manifest?["softwareName"].truthyValue)?.jsString ?? Path.basename(dir)
    let hasBundle = FS.isDirectory(paths.bundle(softwareName))
    let screenFiles = (FS.list(paths.screens) ?? []).filter { Rx.test("^screen-[0-9]+\\.png$", $0, "i") }.sorted()
    if content == nil, !hasBundle, screenFiles.isEmpty { return nil }
    let mtime = FS.mtimeMs(dir) ?? 0
    var grade = "readonly"
    let contentScreens = content?["screens"].items ?? []
    if !contentScreens.isEmpty, screenFiles.count >= contentScreens.count {
        let reviewed = content?["screenshotReview"]?["reviewedScreens"].items ?? []
        var receiptMatches = content?["screenshotReview"]?["status"]?.string == "passed" && reviewed.count == contentScreens.count
        if receiptMatches {
            for index in 0..<contentScreens.count {
                let id = screenId(index)
                let record = reviewed.first { $0["screenId"]?.string == id }
                let file = paths.screenFile(id)
                guard let record, FS.exists(file), record["sha256"]?.string == (try? sha256File(file)) else {
                    receiptMatches = false
                    break
                }
            }
        }
        grade = receiptMatches ? "ready" : "needs-gate"
    }
    return .obj([
        "dir": .string(dir),
        "name": .string(softwareName),
        "grade": .string(grade),
        "screens": .number(Double(contentScreens.isEmpty ? screenFiles.count : contentScreens.count)),
        "hasBundle": .bool(hasBundle),
        "hasPlan": .bool(FS.exists(paths.screenPlan)),
        "hasCodeDoc": .bool(hasBundle && FS.exists(Path.join(paths.bundle(softwareName), "\(softwareName)指南_代码-（JAVA）.docx"))),
        "mtime": .number(mtime),
    ])
}

/// 为历史项目建立状态（不改动项目文件夹里的任何文件）。
public func createImportedState(_ dir: String, _ info: JSON) throws -> JSON {
    let paths = projectPaths(dir)
    let content = FS.readJSONQuiet(paths.content)
    let manifest = FS.readJSONQuiet(paths.manifest)
    let name = info["name"]?.jsString ?? Path.basename(dir)
    let contentScreens = content?["screens"].items ?? []
    var req = ProjectRequest(.emptyObject)
    req.softwareName = name
    req.versionPolicy = (content?["versionPolicy"].truthyValue ?? manifest?["versionPolicy"].truthyValue)?.jsString ?? "in-name"
    req.applicableVersion = content?["applicableVersion"].text ?? ""
    if contentScreens.isEmpty {
        if let count = info["screens"]?.int, count != 0 { req.screenCount = count } else { req.raw["screenCount"] = .null }
    } else {
        req.screenCount = contentScreens.count
    }
    if let createdAt = (content?["createdAt"].truthyValue ?? manifest?["createdAt"].truthyValue)?.jsString { req.createdAt = createdAt }
    if let date = [content?["contentDate"].text, manifest?["contentDate"].text].compactMap({ $0 }).first(where: validContentDate) {
        req.contentDate = date
    }
    if let date = [content?["earliestDate"].text, manifest?["earliestDate"].text].compactMap({ $0 }).first(where: validContentDate) {
        req.earliestDate = date
    }
    if let override = content?["compileDateOverride"]?.string {
        req.compileDate = override
    } else if let compileDate = content?["compileDate"]?.string, let date = req.contentDate, compileDate != contentDateChinese(date) {
        req.compileDate = compileDate
    }
    req.wantDesign = !(content?["design"]?["sections"]?.array?.isEmpty ?? true)
    req.raw["origin"] = "imported"
    var state = ProjectState(newState(req.raw))
    let importedAt = isoNow()
    let grade = info["grade"]?.string ?? "readonly"
    let hasCodeDoc = info["hasCodeDoc"].isTruthy
    state.imported = .obj(["grade": .string(grade), "importedAt": .string(importedAt), "hadCodeDoc": .bool(hasCodeDoc)])
    state.readOnly = (grade == "readonly")
    if hasCodeDoc {
        state.warnings = .array(state.warnings.items + ["这个历史项目的代码文档来自旧 skill 内置的固定正文，不是这个软件的代码。重建前请在「交付」里指定代码来源；不指定则重建后不含代码文档（旧交付包会先归档）。"])
    }
    if grade == "readonly" { return state.raw }

    func makeStep(_ status: StepStatus, finishedAt: String? = nil, message: String? = nil, includeNullMessage: Bool = false) -> StepState {
        var s = StepState(.emptyObject)
        s.status = status
        if let finishedAt { s.finishedAt = finishedAt }
        if let message { s.message = message } else if includeNullMessage { s.clearMessage() }
        return s
    }

    let plan = FS.readJSONQuiet(paths.screenPlan)
    if plan != nil { state[step: .plan] = makeStep(.done, finishedAt: importedAt, message: "沿用历史规划") }
    var promptsAll = !contentScreens.isEmpty
    for index in 0..<contentScreens.count where !FS.exists(paths.promptFile(screenId(index))) { promptsAll = false }
    // 缺标准提示词文件的历史项目也算「提示词」完成：只有真要重生某一屏时才补写那一屏的提示词
    if plan != nil { state[step: .prompts] = makeStep(.done, finishedAt: importedAt, message: promptsAll ? nil : "部分提示词不是标准文件名，重生时再补写", includeNullMessage: promptsAll) }
    if !contentScreens.isEmpty {
        state[step: .images] = makeStep(.done, finishedAt: importedAt)
        state[step: .content] = makeStep(.done, finishedAt: importedAt)
        state[step: .design] = makeStep(content?["design"]?["sections"]?.array?.isEmpty ?? true ? .skipped : .done)
        let tokensHash = hashObject(JSON(forbiddenBrandTokens(name)))
        for index in 0..<contentScreens.count {
            let id = screenId(index)
            let file = paths.screenFile(id)
            guard FS.exists(file) else { continue }
            let sha = try sha256File(file)
            var screen = ScreenState(.emptyObject)
            screen.imageSha = sha
            if grade == "ready" {
                screen.gate = .obj(["status": "passed", "method": "imported-receipt", "sha": .string(sha), "tokensHash": .string(tokensHash), "checkedAt": .string(importedAt), "reasons": []])
            }
            state[screen: id] = screen
        }
        if grade == "ready" {
            state[step: .gate] = makeStep(.done, finishedAt: importedAt, message: "沿用历史审查回执")
            state[step: .receipt] = makeStep(.done, finishedAt: importedAt)
            if info["hasBundle"].isTruthy { state[step: .build] = makeStep(.done, finishedAt: importedAt, message: "沿用历史交付包") }
        }
    }
    let allDone = state.steps.fields.keys.allSatisfy {
        let status = state[step: PipelineStepName(rawValue: $0)]?.status
        return status == .done || status == .skipped
    }
    state.status = allDone ? .done : .idle
    return state.raw
}
