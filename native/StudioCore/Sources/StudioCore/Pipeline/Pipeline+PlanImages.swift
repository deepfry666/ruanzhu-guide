import Foundation

extension Pipeline {
    // MARK: - S1 规划

    func stepPlan(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let request = ctx.state.request
        let settings = ctx.settings
        let platform = platformOf(ctx.state, settings)
        let screenCount = request?.screenCount.flatMap { $0 != 0 ? $0 : nil }
        let name = softwareName(ctx.state)
        // 没设过内容日期的老项目：这次重新规划起按今天算，记下来以后固定
        var planState = ctx.state
        if !dateRuleActive(planState) {
            let today = localDateKey()
            planState = try await updateState(dir) { draft in
                var req = draft.request ?? ProjectRequest(.emptyObject)
                req.contentDate = today
                draft.request = req
            }
        }
        let appClass = await appProfile(dir, planState)
        let emphasis = request?.emphasis ?? ""
        let notes = request?.notes ?? ""
        let nameText = [name, emphasis, notes].joined(separator: " ")
        try await log(dir, "正在让大模型规划界面…")
        var plan = try await callLlm("plan", dir, ChatJsonRequest(
            system: PLAN_SYSTEM_V3,
            user: planUserPromptV3(softwareName: name, screenCount: screenCount, emphasis: emphasis, notes: notes, platform: platform, profile: appClass)
                + platformNeutralRule(name, forPlan: true) + planDateRule(planState, appClass) + planRealDataRule(appClass, text: nameText) + planSceneRule(appClass, text: nameText) + RED_LINE_RULE,
            schema: PLAN_SCHEMA_V3,
            check: { planCheck($0, softwareName: name, screenCount: screenCount) + platformProblems(name, "规划的用户、流程或界面文字", planVisibleTexts($0)) },
            softCheck: { redLineProblems("规划的用户、流程或界面文字", planVisibleTexts($0)) + trafficCodeProblems(appClass, "规划的示例数据", planDatedTexts($0)) },
            temperature: 0.8,
            maxTokens: 8000
        ))
        // 范围外的日期由程序直接改到范围内，不再让大模型整份重写
        let fixes = outOfRangeDateFixes(planDatedTexts(plan), planState)
        if !fixes.isEmpty {
            plan = applyDateFixes(plan, fixes)
            try await log(dir, "规划里有 \(fixes.count) 处日期不在范围内，已改：\(fixes.prefix(6).map { "\($0.0)→\($0.1)" }.joined(separator: "、"))")
        }
        let paths = projectPaths(dir)
        let tokens = forbiddenBrandTokens(name, extraTokens(ctx.state))
        let screens = plan["screens"].items
        let profile = plan["profile"] ?? .emptyObject
        try FS.writeJSONAtomic(paths.profile, .obj([
            "softwareName": .string(name), "versionPolicy": request?.versionPolicy.map(JSON.string), "domain": profile["domain"], "platform": .string(platform),
            "targetUser": profile["targetUser"], "coreFlow": profile["coreFlow"],
            "screenshotPolicy": "UI 内严禁出现软件名称、App 名称、版本号、名称型 logo 或 wordmark",
        ]))
        let features: [JSON] = plan["features"].items.enumerated().map { index, feature in
            .obj(["id": .string("feature-\(String(index + 1).padStart(2))"), "screenId": feature["screenId"], "name": feature["name"], "tier": feature["tier"].or("core"), "mandatory": true, "screenshot": true])
        }
        try FS.writeJSONAtomic(paths.featureMap, .obj(["softwareName": .string(name), "screenshotCount": .number(Double(screens.count)), "coverageReason": plan["coverageReason"], "features": .array(features)]))
        let planScreens: [JSON] = screens.map { screen in
            var next = screen
            next["image"] = .string("screens/\(screen["id"]?.jsString ?? "undefined").png")
            return next
        }
        try FS.writeJSONAtomic(paths.screenPlan, .obj(["softwareName": .string(name), "screenshotCount": .number(Double(screens.count)), "targetSize": .string(settings.image.targetSize), "imageRoute": "image-gateway", "ledger": plan["ledger"].or([]), "screens": .array(planScreens)]))
        let ui = plan["uiContract"] ?? .emptyObject
        let nav = ui["navigation"].or(.emptyObject)
        var uiContract = JSONObject()
        uiContract["platform"] = .string(platform)
        uiContract["viewport"] = .obj(["orientation": "portrait", "requestedSize": .string(settings.image.targetSize), "safeAreas": "native"])
        uiContract["visualStyle"] = ui["visualStyle"]
        uiContract["visual"] = .obj(["palette": ui["palette"], "typography": ui["typography"], "radius": ui["radius"], "shadow": ui["shadow"], "density": ui["density"]])
        uiContract["palette"] = ui["palette"]
        uiContract["typography"] = ui["typography"]
        uiContract["radius"] = ui["radius"]
        uiContract["shadow"] = ui["shadow"]
        uiContract["density"] = ui["density"]
        uiContract["statusBarPolicy"] = .obj(["mode": "consistent", "battery": "same style across screens"])
        uiContract["navigation"] = .obj(["type": nav["type"], "labels": nav["labels"].or([]), "order": nav["labels"].or([]), "iconSemantics": nav["iconSemantics"].or([])])
        uiContract["forbiddenVisibleBranding"] = JSON(tokens + ["App name", "name-bearing logo", "wordmark"])
        try FS.writeJSONAtomic(paths.uiContract, .object(uiContract))
        // 重新规划后界面都变了：人工改过的提示词和说明不再对应，清掉标记让它们按新规划重写
        try await updateState(dir) { draft in
            for id in draft.screens.fields.keys {
                var screen = draft[screen: id] ?? ScreenState(.emptyObject)
                screen.promptEdited = false
                screen.textEdited = false
                draft[screen: id] = screen
            }
            draft.overviewEdited = false
        }
        try await log(dir, "规划完成：\(screens.count) 屏（\(jsJoin(screens.map { $0["title"] ?? .null }, "、"))）")
        return StepOutcome(status: ctx.reviewPlan ? .review : .done, screenCountReason: plan["coverageReason"]?.jsString)
    }

    // MARK: - S2 提示词

    func stepPrompts(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = ctx.state
        let settings = ctx.settings
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let paths = projectPaths(dir)
        try FS.mkdirp(paths.prompts)
        let platform = platformOf(state, settings)
        let ui = normalizedUi(plan)
        let name = softwareName(state)
        struct PromptPatch: Sendable {
            let rowHash: String
            let promptHash: String
            let promptEdited: Bool?
        }
        var screenStates: [String: PromptPatch] = [:]
        var screenOrder: [String] = []
        for screen in plan["screens"].items {
            let id = screen["id"]?.jsString ?? ""
            let rowHash = planRowHash(screen, ui, platform, settings.image.targetSize)
            let previous = state[screen: id]
            let file = paths.promptFile(id)
            // JS 的 `a && b && c`：promptEdited 没设置时保持「没有这个字段」
            var keepValue: Bool?
            if let edited = previous?.promptEdited {
                keepValue = edited ? (previous?.planRowHash == rowHash && FS.exists(file)) : false
            }
            let keep = keepValue == true
            var prompt: String
            var promptHash: String
            if keep {
                // 人工改过或历史项目的提示词：原样保留，只把旧软件名换成新名字。
                // 内容没变时沿用原来的哈希，不会因此重新生图。
                let current = try FS.readText(file)
                let oldName = state.promptsName ?? ""
                prompt = !oldName.isEmpty && oldName != name ? current.replacingAll(oldName, with: name) : current
                if prompt == current, let prevHash = previous?.promptHash, !prevHash.isEmpty {
                    promptHash = prevHash
                } else {
                    promptHash = promptIdentity(prompt, name)
                }
            } else {
                prompt = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
                promptHash = promptIdentity(prompt, name)
            }
            // 历史项目改名和无改动续跑保留旧截图；新项目或主动设置日期后应用规则。
            if let contentDate = state.request?.contentDate, !contentDate.isEmpty {
                prompt = ensureContentDateRule(prompt, state)
                promptHash = promptIdentity(prompt, name)
            }
            if FS.readTextIfExists(file) != prompt { try FS.writeAtomic(file, prompt) }
            if screenStates[id] == nil { screenOrder.append(id) }
            screenStates[id] = PromptPatch(rowHash: rowHash, promptHash: promptHash, promptEdited: keepValue)
        }
        let patches = screenStates
        let order = screenOrder
        try await updateState(dir) { draft in
            for id in order {
                guard let patch = patches[id] else { continue }
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.planRowHash = patch.rowHash
                shot.promptHash = patch.promptHash
                shot.promptEdited = patch.promptEdited
                draft[screen: id] = shot
            }
            for id in draft.screens.fields.keys where patches[id] == nil { draft[screen: id] = nil }
            draft.promptsName = draft.request?.softwareName
        }
        return StepOutcome(status: .done)
    }

    /// retryHint：只用于这一次生成的补充要求（例如上一张验收没过的原因），不写进提示词文件。
    func generateScreen(_ ctx: StepContext, _ id: String, reason: String? = nil, retryHint: String? = nil) async throws -> GenerateResult {
        let dir = ctx.projectDir
        let state = ctx.state
        let paths = projectPaths(dir)
        let name = softwareName(state)
        var prompt: String
        if FS.exists(paths.promptFile(id)) {
            prompt = try FS.readText(paths.promptFile(id))
        } else {
            // 历史项目缺这一屏的标准提示词：按规划现拼一份再生成
            let settings = ctx.settings
            guard let plan = try readPlan(dir), let screen = plan["screens"].items.first(where: { $0["id"]?.string == id }) else {
                throw StudioError("\(id) 没有提示词，规划里也找不到这一屏")
            }
            let platform = platformOf(state, settings)
            let ui = normalizedUi(plan)
            prompt = composeScreenPrompt(softwareName: name, platform: platform, targetSize: settings.image.targetSize, ui: ui, screen: screen)
            try FS.mkdirp(paths.prompts)
            try FS.writeAtomic(paths.promptFile(id), prompt)
            let pHash = promptIdentity(prompt, name)
            let rHash = planRowHash(screen, ui, platform, settings.image.targetSize)
            try await updateState(dir) { draft in
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.promptHash = pHash
                shot.planRowHash = rHash
                shot.promptEdited = false
                draft[screen: id] = shot
            }
        }
        if dateRuleActive(state) {
            let ruled = ensureContentDateRule(prompt, state)
            if ruled != prompt {
                prompt = ruled
                try FS.writeAtomic(paths.promptFile(id), prompt)
                // 提示词因日期规则更新：同步记下新哈希，否则下次运行会以为提示词改过，又把这一屏重生一遍
                let hash = promptIdentity(prompt, name)
                try await updateState(dir) { draft in
                    var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                    shot.promptHash = hash
                    draft[screen: id] = shot
                }
            }
        }
        let sentPrompt = retryHint.map { ensureBrandBan(prompt.replacingAll(BRAND_BAN_BLOCK, with: "").jsTrimmedEnd + "\n\nThis attempt must fix the previous review result: \($0)") } ?? prompt
        emit(.obj(["type": "screen", "projectDir": .string(dir), "screenId": .string(id), "status": "generating", "reason": JSON.maybe(reason)]))
        setScreenProgress(dir, id, ["status": .string(reason != nil ? "regenerating" : "generating"), "startedAt": .number(nowMs()), "finishedAt": nil, "provider": nil, "hedged": false])
        let result = try await gateway.generate(GenerateRequest(
            projectDir: dir, projectName: name, screenId: id, prompt: sentPrompt, outputPath: paths.screenFile(id),
            alternatesDir: paths.alternates, archiveRoot: paths.archive, batchId: ctx.batchId
        ))
        let imageSha = try sha256File(paths.screenFile(id))
        let promptHash = promptIdentity(prompt, name)
        let generatedAt = isoNow()
        let durationSec = Int(jsRound(result.durationMs / 1000))
        try await updateState(dir) { draft in
            var shot = draft[screen: id] ?? ScreenState(.emptyObject)
            shot.imagePromptHash = promptHash
            shot.imageSha = imageSha
            shot.providerId = result.providerId
            shot.providerName = result.providerName
            shot.model = result.model
            if let size = result.requestSize { shot.requestSize = size }
            if let width = result.width { shot.width = width }
            if let height = result.height { shot.height = height }
            shot.hedged = result.hedged
            shot.imageWarnings = JSON(result.warnings)
            shot.generatedAt = generatedAt
            shot.gate = .null
            // 截图换了，这一屏的说明要按新截图重写（人工改过的会保留并提醒）
            shot.contentStale = true
            draft[screen: id] = shot
            appendLog(&draft, "\(id) 已生成（\(result.providerName.isEmpty ? result.providerId : result.providerName)\(result.hedged ? "，触发了超时补发" : "")，\(durationSec) 秒）")
        }
        let promptSha = sha256Hex(prompt)
        try await updateRecord(dir) { record in
            let entry: JSON = .obj([
                "source": "generated", "providerId": .string(result.providerId), "providerName": .string(result.providerName), "model": .string(result.model),
                "requestSize": JSON.maybe(result.requestSize), "width": JSON.maybe(result.width), "height": JSON.maybe(result.height), "hedged": .bool(result.hedged),
                "attempts": .number(Double(result.attempts)), "resumed": .bool(result.resumed), "generatedAt": .string(generatedAt),
                "imageSha256": .string(imageSha), "promptSha256": .string(promptSha), "reason": JSON.orNull(reason),
            ])
            record["screens"]?[id] = entry
            record.append("history", JSON.obj(["at": .string(generatedAt), "event": "screen-generated", "screenId": .string(id)]).merging(entry))
        }
        emit(.obj(["type": "screen", "projectDir": .string(dir), "screenId": .string(id), "status": "generated"]))
        setScreenProgress(dir, id, ["status": "generated", "finishedAt": .number(nowMs()), "provider": .string(result.providerName.isEmpty ? result.providerId : result.providerName), "hedged": .bool(result.hedged)])
        return result
    }

    // MARK: - S3 生图

    func stepImages(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readTypedState(dir)
        let paths = projectPaths(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        var needed: [String] = []
        let planScreens = plan["screens"].items
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            let current = state[screen: id]
            let forced = ctx.forceScreens?.contains(id) ?? false
            let imagePromptHash = current?.imagePromptHash ?? ""
            if forced || !FS.exists(paths.screenFile(id))
                || (!imagePromptHash.isEmpty && imagePromptHash != current?.promptHash)
                || (imagePromptHash.isEmpty && state.origin != "imported") {
                needed.append(id)
            }
        }
        if needed.isEmpty { return StepOutcome(status: .done) }
        var screensProgress = JSONObject()
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            screensProgress[id] = needed.contains(id) ? ["status": "waiting"] : ["status": "kept"]
        }
        setProgress(dir, .obj(["screens": .object(screensProgress)]))
        try await log(dir, "开始生成 \(needed.count) 张截图（同时发出）")
        var screenCtx = ctx
        screenCtx.state = state
        let generationCtx = screenCtx
        let outcomes: [(String, String?)] = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, id) in needed.enumerated() {
                group.addTask {
                    do {
                        _ = try await self.generateScreen(generationCtx, id)
                        return (index, nil)
                    } catch {
                        self.setScreenProgress(dir, id, ["status": "failed", "finishedAt": .number(nowMs()), "error": .string(messageOf(error))])
                        return (index, messageOf(error))
                    }
                }
            }
            var results = [(String, String?)](repeating: ("", nil), count: needed.count)
            for await (index, failure) in group { results[index] = (needed[index], failure) }
            return results
        }
        let failures = outcomes.compactMap { id, message in message.map { (id, $0) } }
        if !failures.isEmpty {
            let messages = uniqued(failures.map(\.1))
            let detail = messages.count == 1 ? "\(failures.map(\.0).joined(separator: "、"))：\(messages[0])" : failures.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
            throw StudioError("\(failures.count) 张截图没有生成成功\(failures.count < needed.count ? "（其余已保存）" : "")：\n\(detail)")
        }
        return StepOutcome(status: .done)
    }
}
