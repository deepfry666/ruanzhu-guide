import Foundation

// MARK: - 修改意见：改数据
//
// 「违法代码要用真实的」「本月条数和列表对不上」这类意见，问题出在数据上，不在画面上。
// 先让大模型按要求改数据底账和各屏示例数据（附上内置真实数据和日期规定），程序再修正日期、核对违法代码，
// 写回规划；数据变了的屏重新拼提示词、重生截图，说明跟着按新截图重写。

public let DATA_EDIT_SYSTEM = """
你负责按修改要求改一个手机 App 用户手册的示例数据。给你数据底账 ledger 和每屏的示例数据 sampleData、应包含 mustShow。
1. 只改修改要求涉及的数据，其余原样保留，写法不变。
2. 底账里的一条改了，用到它的各屏都要跟着改；条数、合计、「本月」「近 7 天」这类汇总按改后的底账重新算对。
3. 要求用真实数据时，只能用给出的真实数据；给出的数据里没有的，不写具体编号、金额、比例，用名称或「详情」代替。
4. 输出完整的新 ledger，以及有改动的屏：id、完整的新 sampleData、完整的新 mustShow。没改动的屏不要输出。
5. summary 用一句话说改了什么。
"""

public let DATA_EDIT_SCHEMA: JSON = .obj([
    "type": "object",
    "required": ["summary", "ledger", "screens"],
    "properties": .obj([
        "summary": .obj(["type": "string"]),
        "ledger": .obj(["type": "array", "items": .obj(["type": "string"])]),
        "screens": .obj(["type": "array", "items": .obj([
            "type": "object",
            "required": ["id", "sampleData", "mustShow"],
            "properties": .obj([
                "id": .obj(["type": "string"]),
                "sampleData": .obj(["type": "array", "items": .obj(["type": "string"])]),
                "mustShow": .obj(["type": "array", "items": .obj(["type": "string"])]),
            ]),
        ])]),
    ]),
])

public func dataEditUserPrompt(softwareName: String, instruction: String, ledger: [String], screens: [JSON], rules: String) -> String {
    var lines = ["软件名（仅作上下文，界面里不能显示）：\(softwareName)", "修改要求：\(instruction)", "", "数据底账 ledger："]
    lines.append(contentsOf: ledger.isEmpty ? ["（还没有底账，按各屏示例数据整理出一份）"] : ledger.map { "- \($0)" })
    lines.append("")
    lines.append("各屏：")
    for screen in screens {
        lines.append("【\(screen["id"].text)｜\(screen["title"].text)】")
        lines.append("sampleData：\(screen["sampleData"].items.map(\.jsString).joined(separator: " / "))")
        lines.append("mustShow：\(screen["mustShow"].items.map(\.jsString).joined(separator: " / "))")
    }
    lines.append(rules)
    lines.append("")
    lines.append(#"输出 JSON：{"summary":"","ledger":[""],"screens":[{"id":"screen-01","sampleData":[],"mustShow":[]}]}"#)
    return lines.joined(separator: "\n")
}

public func dataEditCheck(_ result: JSON, screenIds: [String]) -> [String] {
    let wrong = result["screens"].items.map(\.["id"].text).filter { !screenIds.contains($0) }
    return wrong.isEmpty ? [] : ["screens 里的 id 只能是 \(screenIds.joined(separator: "/"))，现在有 \(wrong.joined(separator: "、"))"]
}

extension Pipeline {
    /// 按修改要求改数据底账和示例数据，写回规划，并给数据变了的屏重新拼好提示词。返回数据变了的屏。
    func applyDataEdit(_ dir: String, _ state: JSON, _ instruction: String) async throws -> [String] {
        let paths = projectPaths(dir)
        guard var raw = try FS.readJSON(paths.screenPlan), let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let screens = plan["screens"].items
        let screenIds = screens.map { $0["id"].text }
        let name = softwareName(state)
        let profile = AppProfile(state["appProfile"]) ?? keywordAppProfile(name)
        let rules = planRealDataRule(profile, text: name) + planDateRule(state, profile) + RED_LINE_RULE
        let result = try await callLlm("feedback", dir, ChatJsonRequest(
            system: DATA_EDIT_SYSTEM,
            user: dataEditUserPrompt(softwareName: name, instruction: instruction, ledger: raw["ledger"].items.map(\.jsString), screens: screens, rules: rules),
            schema: DATA_EDIT_SCHEMA,
            check: { dataEditCheck($0, screenIds: screenIds) },
            softCheck: {
                let texts = $0["ledger"].items.map(\.jsString) + $0["screens"].items.flatMap { ($0["sampleData"].items + $0["mustShow"].items).map(\.jsString) }
                return trafficCodeProblems(profile, "改后的数据", texts) + redLineProblems("改后的数据", texts)
            },
            temperature: 0.3,
            maxTokens: 6000
        ))
        // 改后的数据写回规划文件（只动底账和有改动的屏）
        var next = plan
        next["ledger"] = result["ledger"]
        let patches = Dictionary(result["screens"].items.map { ($0["id"].text, $0) }, uniquingKeysWith: { first, _ in first })
        next["screens"] = .array(screens.map { screen in
            guard let patch = patches[screen["id"].text] else { return screen }
            return screen.merging(.obj(["sampleData": patch["sampleData"] ?? .array([]), "mustShow": patch["mustShow"] ?? .array([])]))
        })
        let fixes = outOfRangeDateFixes(planDatedTexts(next), state)
        next = applyDateFixes(next, fixes)
        let changed = zip(screens, next["screens"].items).compactMap { old, new -> String? in
            old["sampleData"] == new["sampleData"] && old["mustShow"] == new["mustShow"] ? nil : new["id"].text
        }
        raw["ledger"] = next["ledger"]
        let rowsKey = raw["screens"] != nil ? "screens" : raw["flow"] != nil ? "flow" : nil
        if let rowsKey {
            raw[rowsKey] = .array(raw[rowsKey].items.map { row in
                guard let updated = next["screens"].items.first(where: { $0["id"].text == row["id"].text }) else { return row }
                return row.merging(.obj(["sampleData": updated["sampleData"] ?? .array([]), "mustShow": updated["mustShow"] ?? .array([])]))
            })
        }
        try FS.writeJSONAtomic(paths.screenPlan, raw)

        // 数据变了的屏现在就重新拼提示词，后面「改图」的动作在新提示词上改，不会被覆盖
        let settings = try await settingsStore.get()
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        var patchesById: [String: JSON] = [:]
        try FS.mkdirp(paths.prompts)
        for id in changed {
            guard let screen = next["screens"].items.first(where: { $0["id"].text == id }) else { continue }
            var prompt = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
            if dateRuleActive(state) { prompt = ensureContentDateRule(prompt, state) }
            try FS.writeAtomic(paths.promptFile(id), prompt)
            patchesById[id] = .obj(["planRowHash": .string(planRowHash(screen, ui, platform, settings.image.targetSize)), "promptHash": .string(promptIdentity(prompt, name)), "promptEdited": false])
        }
        let summary = result["summary"].text
        let fixed = fixes.count
        let all = patchesById
        try await update(dir) { draft in
            for (id, patch) in all { draft.mergeChild("screens", id, patch) }
            appendLog(&draft, "按修改意见改数据：\(summary.isEmpty ? instruction : summary)（\(changed.isEmpty ? "各屏数据没有变化" : "数据变了的屏：\(changed.joined(separator: "、"))")\(fixed > 0 ? "，另改了 \(fixed) 处范围外的日期" : "")）")
        }
        return changed
    }
}
