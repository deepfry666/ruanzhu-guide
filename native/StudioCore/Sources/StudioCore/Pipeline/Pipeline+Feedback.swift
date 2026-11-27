import Foundation

extension Pipeline {
    // MARK: - 修改意见：先攒清单，再整理，确认后统一修改

    /// target：指定改哪里（screen-XX / all / overview / design），nil 表示让软件判断。
    @discardableResult
    public func addFeedback(_ dir: String, _ text: String, target: String? = nil) async throws -> JSON {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        var item = FeedbackItem(.emptyObject)
        item.id = randomHex(4)
        item.text = value
        item.at = isoNow()
        item.status = "pending"
        if let target, !target.isEmpty { item.target = target }
        let added = item
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []) + [added]
            draft.feedbackPlan = .null
        }
        return added.raw
    }

    public func editFeedback(_ dir: String, _ id: String, _ text: String) async throws {
        try assertEditable(dir)
        let value = text.jsTrimmed
        if value.isEmpty { throw StudioError("修改意见是空的") }
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).map { item in
                guard item.id == id, item.status == "pending" else { return item }
                var next = item
                next.text = value
                return next
            }
            draft.feedbackPlan = .null
        }
    }

    public func setFeedbackTarget(_ dir: String, _ id: String, _ target: String?) async throws {
        try assertEditable(dir)
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).map { item in
                guard item.id == id, item.status == "pending" else { return item }
                var next = item
                next.target = target.flatMap { $0.isEmpty ? nil : $0 }
                return next
            }
            draft.feedbackPlan = .null
        }
    }

    public func removeFeedback(_ dir: String, _ id: String) async throws {
        try assertEditable(dir)
        try await updateState(dir) { draft in
            draft.feedback = (draft.feedback ?? []).filter { $0.id != id }
            draft.feedbackPlan = .null
        }
    }

    /// 把清单里所有未处理的意见一起交给大模型，整理成「改哪几张图、重写哪几段文字」。
    public func analyzeFeedback(_ dir: String) async throws -> JSON {
        try assertEditable(dir)
        guard let state = try projectStore.readTyped(dir) else { throw StudioError("项目不存在") }
        if state.readOnly == true { throw StudioError("只读的历史项目不能修改") }
        let items = (state.feedback ?? []).filter { $0.status == "pending" }
        if items.isEmpty { throw StudioError("清单里没有待处理的修改意见") }
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划，先运行一次再提修改意见") }
        let content = try FS.readJSON(projectPaths(dir).content)
        var contentById: [String: JSON] = [:]
        for (index, screen) in (content?["screens"].items ?? []).enumerated() { contentById[screen["id"].or(.string(screenId(index))).jsString] = screen }
        let screens: [FeedbackScreenInfo] = plan["screens"].items.enumerated().map { index, screen in
            let id = screen["id"]?.jsString ?? ""
            let gate = state[screen: id]?.gate
            let inventory = gate?["inventory"].text ?? ""
            return FeedbackScreenInfo(
                figure: "图\(index + 1)",
                id: id,
                title: (contentById[id]?["title"].truthyValue ?? screen["title"] ?? .null).jsString,
                picture: inventory.isEmpty ? screen["visualBrief"].text : inventory,
                visibleText: gate?["visibleText"].items.map(\.jsString) ?? [],
                text: contentById[id]?["text"].text ?? "",
                sampleData: screen["sampleData"].items.map(\.jsString)
            )
        }
        let screenIds = screens.map(\.id)
        let hasDesign = state.request?.wantDesign == true || !(content?["design"]?["sections"]?.array?.isEmpty ?? true)
        let inputs = items.map { FeedbackInput(text: $0.text ?? "", target: feedbackTargetValid($0.target, screenIds: screenIds, hasDesign: hasDesign)) }
        // 整理失败（模型出错、格式不对）也不报错退出：按用户指定的位置列出，其余的在确认窗口里选位置
        var raw: JSON = .obj(["summary": "", "actions": [], "questions": []])
        var notice: String?
        do {
            raw = try await callLlm("feedback", dir, ChatJsonRequest(
                system: FEEDBACK_SYSTEM_NATIVE,
                user: feedbackUserPromptNative(softwareName: softwareName(state), screens: screens, overview: content?["cover"]?["overview"].text ?? "", hasDesign: hasDesign, items: inputs, profile: AppProfile(state.appProfile), ledger: plan["ledger"].items.map(\.jsString)),
                schema: FEEDBACK_SCHEMA_NATIVE,
                temperature: 0.2,
                maxTokens: 4000
            ))
        } catch {
            notice = "自动整理没有成功（\(messageOf(error).jsSlice(0, 120))）。指定了位置的意见已直接列出，其余的请在下面选择要改哪里。"
        }
        let repaired = repairFeedbackResult(raw, items: inputs, screenIds: screenIds, hasDesign: hasDesign)
        let result: JSON = .obj(["summary": raw["summary"].or(""), "actions": .array(repaired.actions), "questions": .array(repaired.questions)])
        func toIds(_ indexes: JSON?) -> [String] {
            uniqued((indexes?.array ?? []).compactMap { value -> String? in
                guard let number = value.number, number >= 1, Int(number) <= items.count else { return nil }
                return items[Int(number) - 1].id
            })
        }
        func labelOf(_ target: String) -> String { target == "all" ? "全部" : feedbackTargetLabel(target, screens: screens) }
        // 整理结果再规范一遍：「全部截图」展开成每一屏；同一屏同一类型合并；有重新规划时其余截图/说明动作并进去
        var merged: [(key: String, value: JSON)] = []
        for action in result["actions"].items {
            let type = action["type"]?.jsString ?? ""
            let target = action["target"]?.jsString ?? ""
            let targets = type == "image" && target == "all" ? screenIds : [type == "overview" ? "overview" : type == "design" ? "design" : type == "replan" ? "all" : target]
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            for target in targets {
                let key = "\(type):\(target)"
                if let position = merged.firstIndex(where: { $0.key == key }) {
                    var previous = merged[position].value
                    previous["instruction"] = .string("\(previous["instruction"]?.jsString ?? "")；\(instruction)")
                    previous["items"] = JSON(uniqued(previous["items"].items.map(\.jsString) + toIds(action["items"])))
                    merged[position].value = previous
                } else {
                    merged.append((key, .obj(["key": .string(key), "type": .string(type), "target": .string(target), "targetLabel": .string(labelOf(target)), "instruction": .string(instruction), "items": JSON(toIds(action["items"]))])))
                }
            }
        }
        var actions = merged.map(\.value)
        if let replanIndex = actions.firstIndex(where: { $0["type"]?.string == "replan" }) {
            var replan = actions[replanIndex]
            let others = actions.enumerated().filter { $0.offset != replanIndex && ["data", "image", "text"].contains($0.element["type"]?.string ?? "") }
            replan["items"] = JSON(uniqued(replan["items"].items.map(\.jsString) + others.flatMap { $0.element["items"].items.map(\.jsString) }))
            if !others.isEmpty {
                replan["instruction"] = .string("\(replan["instruction"]?.jsString ?? "")；\(others.map { "\($0.element["targetLabel"]?.jsString ?? "")：\($0.element["instruction"]?.jsString ?? "")" }.joined(separator: "；"))")
            }
            let removed = Set(others.map(\.offset))
            actions[replanIndex] = replan
            actions = actions.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        let order = ["replan": 0, "data": 1, "image": 2, "text": 3, "overview": 4, "design": 5]
        actions = actions.enumerated().sorted { a, b in
            let ta = order[a.element["type"]?.string ?? ""] ?? 9
            let tb = order[b.element["type"]?.string ?? ""] ?? 9
            if ta != tb { return ta < tb }
            let xa = a.element["target"]?.jsString ?? ""
            let xb = b.element["target"]?.jsString ?? ""
            if xa != xb { return localeCompareEn(xa, xb) }
            return a.offset < b.offset
        }.map(\.element)
        let questions: [JSON] = result["questions"].items.map { .obj(["question": $0["question"] ?? "", "items": JSON(toIds($0["items"]))]) }.filter { !($0["question"]?.jsString ?? "").jsTrimmed.isEmpty }
        let feedbackPlan: JSON = .obj([
            "createdAt": .string(isoNow()),
            "notice": JSON.maybe(notice),
            "summary": result["summary"] ?? "",
            "itemIds": JSON(items.compactMap(\.id)),
            "actions": .array(actions),
            "questions": .array(questions),
        ])
        try await updateState(dir) { $0.feedbackPlan = feedbackPlan }
        return feedbackPlan
    }

    /// 按确认后的动作统一修改：先改好所有要重生截图的提示词，再一次运行
    /// （截图同时生成、一起验收、一起重写说明、只构建一次）。actions 是界面上勾选、改过措辞后的动作。
    public func applyFeedback(_ dir: String, actions chosen: [JSON]) async throws -> JSON {
        try assertEditable(dir)
        try assertIdle(dir)
        let entered: Bool = applying.withLock { set in set.insert(dir).inserted }
        if !entered { throw StudioError("正在处理上一次的修改") }
        defer { applying.withLock { _ = $0.remove(dir) } }
        let prepared = try await prepareFeedback(dir, actions: chosen)
        if let options = prepared.options { start(dir, options) }
        return prepared.result
    }

    /// 按修改意见准备好：改数据、改提示词、记下处理了哪些意见，返回这次要怎么运行（不用运行时为 nil）。
    /// 单个项目确认后马上运行；批量修改时交给批量队列按并发运行。
    func prepareFeedback(_ dir: String, actions chosen: [JSON], reviewPlan: Bool? = nil) async throws -> (options: RunOptions?, result: JSON) {
        try assertEditable(dir)
        let state = try readTypedState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let screenIds = plan["screens"].items.map { $0["id"]?.jsString ?? "" }
        // 「全部截图」展开成每一屏
        let expanded: [JSON] = chosen.flatMap { action -> [JSON] in
            guard action["type"]?.string == "image", action["target"]?.string == "all" else { return [action] }
            return screenIds.enumerated().map { index, id in action.merging(.obj(["target": .string(id), "targetLabel": .string("图\(index + 1)")])) }
        }
        // 同一屏同一类型的修改合并成一条（确认窗口里手动加的可能和整理结果重复），免得同时改写同一份提示词
        var actions: [JSON] = []
        for action in expanded {
            let type = action["type"]?.string ?? ""
            let instruction = (action["instruction"]?.jsString ?? "").jsTrimmed
            guard ["data", "image", "text", "overview", "design", "replan"].contains(type), !instruction.isEmpty else { continue }
            let target = ["overview", "design"].contains(type) ? type : type == "data" ? "all" : action["target"]?.jsString ?? ""
            let items = action["items"]?.array ?? []
            if let index = actions.firstIndex(where: { $0["type"]?.string == type && ($0["target"]?.jsString ?? "") == target }) {
                let previous = actions[index]
                let joined = previous["instruction"]?.jsString == instruction ? instruction : "\(previous["instruction"]?.jsString ?? "")；\(instruction)"
                actions[index] = previous.merging(.obj(["instruction": .string(joined), "items": JSON(uniqued(previous["items"].items.map(\.jsString) + items.map(\.jsString)))]))
            } else {
                actions.append(action.merging(.obj(["target": .string(target), "instruction": .string(instruction), "items": .array(items)])))
            }
        }
        for action in actions where ["image", "text"].contains(action["type"]?.string ?? "") {
            let target = action["target"]?.jsString ?? ""
            if !screenIds.contains(target) { throw StudioError("找不到这一屏：\(target)") }
        }
        if actions.isEmpty { throw StudioError("没有勾选任何修改") }
        let replan = actions.first { $0["type"]?.string == "replan" }
        let dataAction = replan != nil ? nil : actions.first { $0["type"]?.string == "data" }
        let imageActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "image" }
        let textActions = replan != nil ? [] : actions.filter { $0["type"]?.string == "text" }
        let overview = actions.first { $0["type"]?.string == "overview" }
        let design = actions.first { $0["type"]?.string == "design" }
        if design != nil, state.request?.wantDesign != true { throw StudioError("这个项目没有开启「设计说明」章节，先在概览里打开") }

        // 0. 改数据：先改底账和示例数据，数据变了的屏重新拼好提示词（后面改图的动作在新提示词上改）
        var dataChanged: [String] = []
        if let dataAction { dataChanged = try await applyDataEdit(dir, state, dataAction["instruction"]?.jsString ?? "") }

        // 1. 改写要重生的截图的提示词（几张同时改）
        let paths = projectPaths(dir)
        let name = softwareName(state)
        let tokens = forbiddenBrandTokens(name, extraTokens(state))
        let settings = try await settingsStore.get()
        let withoutNameLines: @Sendable (String) -> String = { text in
            text.components(separatedBy: "\n").filter { !$0.hasPrefix("Project context exact software name:") && !$0.contains(BRAND_BAN_BLOCK) }.joined(separator: "\n")
        }
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        let editedResults: [Result<(String, String), Error>] = await mapLimit(imageActions, 3) { action, _ in
            do {
                let target = action["target"]?.jsString ?? ""
                var current = FS.readTextIfExists(paths.promptFile(target))
                if current == nil || current!.isEmpty {
                    let screen = plan["screens"].items.first { $0["id"]?.string == target } ?? .emptyObject
                    current = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
                }
                let result = try await self.callLlm("feedback", dir, ChatJsonRequest(
                    system: PROMPT_EDIT_SYSTEM,
                    user: promptEditUserPrompt(prompt: current!, instruction: action["instruction"]?.jsString ?? ""),
                    schema: PROMPT_EDIT_SCHEMA,
                    check: { draft in
                        let hits = findBrandHits([withoutNameLines(draft["prompt"].text)], tokens)
                        return hits.isEmpty ? [] : ["新提示词里出现了软件名/品牌词：\(hits.joined(separator: "、"))，界面上不能出现，请去掉"]
                    },
                    temperature: 0.3,
                    maxTokens: 6000
                ))
                return .success((target, ensureBrandBan(result["prompt"]?.jsString ?? "")))
            } catch {
                return .failure(error)
            }
        }
        var edited: [(String, String)] = []
        for result in editedResults {
            switch result {
            case .success(let item): edited.append(item)
            case .failure(let error): throw error
            }
        }
        try FS.mkdirp(paths.prompts)
        for (id, prompt) in edited { try FS.writeAtomic(paths.promptFile(id), prompt) }

        // 2. 记下这次处理了哪些意见
        let appliedItemIds = uniqued(actions.flatMap { $0["items"].items.map(\.jsString) })
        let at = isoNow()
        let summary = actions.map { "\($0["targetLabel"].truthyValue?.jsString ?? $0["target"]?.jsString ?? "")：\($0["instruction"]?.jsString ?? "")" }.joined(separator: "；")
        let editedList = edited
        // 重生后验收时核对这条修改有没有体现在图上，没有就自动重生
        let requestedChanges: [(String, String)] = imageActions.map { ($0["target"]?.jsString ?? "", $0["instruction"]?.jsString ?? "") }
        let textTargets = textActions.map { $0["target"]?.jsString ?? "" }
        let replanInstruction = replan?["instruction"]?.jsString
        let hasOverview = overview != nil
        try await updateState(dir) { draft in
            let currentName = draft.request?.softwareName ?? ""
            for (id, prompt) in editedList {
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.promptEdited = true
                shot.promptHash = promptIdentity(prompt, currentName)
                draft[screen: id] = shot
            }
            for (id, change) in requestedChanges where !id.isEmpty && !change.isEmpty {
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.requestedChange = change
                draft[screen: id] = shot
            }
            for target in textTargets {
                guard var shot = draft[screen: target] else { continue }
                shot.textEdited = false
                draft[screen: target] = shot
            }
            if hasOverview { draft.overviewEdited = false }
            if let replanInstruction {
                var req = draft.request ?? ProjectRequest(.emptyObject)
                let notes = [req.notes ?? "", "修改意见：\(replanInstruction)"].filter { !$0.isEmpty }.joined(separator: "\n")
                req.notes = notes
                draft.request = req
            }
            let applied = Set(appliedItemIds)
            draft.feedback = (draft.feedback ?? []).map { item in
                guard let itemId = item.id, applied.contains(itemId), item.status == "pending" else { return item }
                var next = item
                next.status = "done"
                next.doneAt = at
                next.appliedAs = summary
                return next
            }
            draft.feedbackPlan = .null
            appendLog(&draft, "按修改意见统一修改：\(summary)")
        }
        let texts: [JSON] = (state.feedback ?? []).filter { appliedItemIds.contains($0.id ?? "") }.map { .obj(["id": $0.id.map(JSON.string), "text": $0.text.map(JSON.string)]) }
        let actionRecords: [JSON] = actions.map { .obj(["type": $0["type"], "target": $0["target"], "instruction": $0["instruction"]]) }
        try await updateRecord(dir) { record in
            let entry: JSON = .obj(["at": .string(at), "items": .array(texts), "actions": .array(actionRecords)])
            record["feedback"] = .array(Array((record["feedback"].items + [entry]).suffix(100)))
            record.append("history", JSON.obj(["event": "feedback"]).merging(entry))
        }

        // 3. 一次运行完成所有修改
        var contentInstructions: [String: String] = [:]
        for action in textActions { contentInstructions[action["target"]?.jsString ?? ""] = action["instruction"]?.jsString ?? "" }
        if let overview { contentInstructions["overview"] = overview["instruction"]?.jsString ?? "" }
        let onlyData = dataAction != nil && actions.allSatisfy { $0["type"]?.string == "data" }
        if onlyData && dataChanged.isEmpty {
            return (nil, .obj(["started": false, "data": 0, "appliedItems": .number(Double(appliedItemIds.count))]))
        }
        let from = replan != nil ? PipelineStepName.plan.rawValue : !imageActions.isEmpty || !dataChanged.isEmpty ? PipelineStepName.prompts.rawValue : !textActions.isEmpty || overview != nil ? PipelineStepName.content.rawValue : PipelineStepName.design.rawValue
        let options = RunOptions(
            from: from,
            force: (replan != nil ? [PipelineStepName.plan.rawValue] : []) + (design != nil ? [PipelineStepName.design.rawValue] : []),
            forceScreens: uniqued(imageActions.map { $0["target"]?.jsString ?? "" } + dataChanged),
            contentInstructions: contentInstructions,
            designInstruction: design?["instruction"]?.jsString,
            reviewPlan: reviewPlan,
            reason: "修改意见"
        )
        return (options, .obj(["started": true, "data": .number(Double(dataChanged.count)), "images": .number(Double(uniqued(imageActions.map { $0["target"]?.jsString ?? "" } + dataChanged).count)), "texts": .number(Double(textActions.count + (overview != nil ? 1 : 0))), "design": .bool(design != nil), "replan": .bool(replan != nil), "appliedItems": .number(Double(appliedItemIds.count))]))
    }
}
