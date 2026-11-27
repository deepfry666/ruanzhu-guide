import Foundation

extension Pipeline {
    // MARK: - S4 品牌验收

    func gateOne(_ ctx: StepContext, _ screen: JSON, _ tokens: [String], _ tokensHash: String, _ llmAvailable: Bool) async throws -> JSON {
        let dir = ctx.projectDir
        let paths = projectPaths(dir)
        let limit = ctx.settings.image.gateRegenerateLimit
        let id = screen["id"]?.jsString ?? ""
        var round = 0
        while true {
            let state = try readTypedState(dir)
            let file = paths.screenFile(id)
            let sha = try sha256File(file)
            if let current = state[screen: id]?.gate, current.isObject, current["sha"]?.string == sha, current["tokensHash"]?.string == tokensHash,
               ["passed", "manual-passed"].contains(current["status"]?.string ?? "") {
                setScreenProgress(dir, id, ["status": "passed"])
                return current
            }
            if !llmAvailable {
                let gate: JSON = .obj(["status": "needs-manual", "sha": .string(sha), "tokensHash": .string(tokensHash), "method": "manual", "checkedAt": .string(isoNow()), "reasons": ["没有配置看图模型，请人工确认截图里没有软件名"]])
                try await updateState(dir) { draft in
                    var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                    shot.gate = gate
                    draft[screen: id] = shot
                }
                return gate
            }
            setScreenProgress(dir, id, ["status": "checking"])
            let image = try visionImage(file)
            let requestedChange = state[screen: id]?.requestedChange?.jsTrimmed ?? ""
            let result = try await callLlm("gate", dir, ChatJsonRequest(
                system: GATE_SYSTEM,
                user: gateUserPrompt(softwareName: softwareName(state), tokens: tokens, screen: screen) + gateChangeQuestion(requestedChange) + GATE_RED_LINE_QUESTION,
                images: [image],
                schema: GATE_SCHEMA,
                temperature: 0.1,
                maxTokens: 4000
            ))
            let verdict = judgeGate(result, tokens)
            var reasons = verdict.reasons
            var retryHints: [String] = []
            // 日期：按看图模型抄下的图上文字复核，早于最早日期就重生
            let earlyDates = dateRuleActive(state)
                ? datesBefore(result["visibleText"].items.map(\.jsString) + [result["screenTitle"].text], earliest: earliestDateOf(state), base: contentDateOf(state))
                : []
            if !earlyDates.isEmpty {
                reasons.append("截图里有早于 \(earliestDateOf(state)) 的日期：\(earlyDates.joined(separator: "、"))")
                retryHints.append("every date shown must be between \(earliestDateOf(state)) and \(contentDateOf(state)); the previous image showed earlier dates: \(earlyDates.joined(separator: ", "))")
            }
            // 今天以后的具体日期（比如生图模型自己画的日期选择条）
            let visibleTexts = result["visibleText"].items.map(\.jsString)
            let laterDates = dateRuleActive(state) ? datesAfter(visibleTexts, base: contentDateOf(state)) : []
            if !laterDates.isEmpty {
                reasons.append("截图里有今天以后的日期：\(laterDates.joined(separator: "、"))")
                retryHints.append("do not show any date after \(contentDateOf(state)) (no future dates, no date strips with upcoming days): \(laterDates.joined(separator: ", "))")
            }
            // 金额：截图上的金额要来自规划的底账和示例数据，生图模型自己补的表格、明细不算数
            if let plan = try? readPlan(dir), !plan["ledger"].items.isEmpty {
                let planTexts = (plan["ledger"].items + plan["screens"].items.flatMap { $0["sampleData"].items + $0["mustShow"].items }).map(\.jsString)
                let extra = unlistedAmounts(visibleTexts, planTexts: planTexts)
                if !extra.isEmpty {
                    reasons.append("截图上有规划里没有的金额：\(extra.prefix(8).joined(separator: "、"))")
                    retryHints.append("show only the amounts listed in the sample values; do not add extra rows, columns, breakdowns or computed amounts (the previous image added: \(extra.prefix(8).joined(separator: ", ")))")
                }
            }
            // 交通违法代码：图上出现没确认过的代码就重生
            let codes = trafficCodeProblems(AppProfile(state.appProfile), "截图", result["visibleText"].items.map(\.jsString)).isEmpty ? [] : unknownTrafficCodes(result["visibleText"].items.map(\.jsString))
            if !codes.isEmpty {
                reasons.append("截图里有没确认过的违法代码：\(codes.joined(separator: "、"))")
                retryHints.append("do not show traffic violation code numbers other than 1625; show only the violation name and its points: \(codes.joined(separator: ", "))")
            }
            // 内容红线：看图模型看画面，再按抄下的文字复核；碰到就重生
            let redTexts = redLineHits(result["visibleText"].items.map(\.jsString) + [result["screenTitle"].text])
            if result["redLine"] == .bool(true) || !redTexts.isEmpty {
                let evidence = [result["redLineEvidence"].text] + redTexts
                reasons.append("截图碰到内容红线：\(evidence.filter { !$0.isEmpty }.joined(separator: "、"))")
                retryHints.append("remove all government / official / political / vulgar elements: \(evidence.filter { !$0.isEmpty }.joined(separator: ", ")); present it as a personal tool")
            }
            // 修改意见：看图模型判断这次的修改有没有体现在图上，没有就重生
            if !requestedChange.isEmpty, result["changeApplied"] == .bool(false) {
                reasons.append("截图没有按修改意见改：\(requestedChange)\(result["changeEvidence"].text.isEmpty ? "" : "（\(result["changeEvidence"].text)）")")
                retryHints.append("the requested change was not visible in the previous image; make it clearly visible: \(requestedChange)")
            }
            let passed = reasons.isEmpty
            let failureReasons = reasons
            let checkedAt = isoNow()
            let gate: JSON = .obj([
                "status": .string(passed ? "passed" : "failed"), "method": "vision", "sha": .string(sha), "tokensHash": .string(tokensHash),
                "reasons": JSON(reasons), "hits": JSON(verdict.hits), "screenTitle": result["screenTitle"].or(""),
                "visibleText": .array(Array(result["visibleText"].items.prefix(80))), "inventory": result["inventory"],
                "warnings": result["warnings"].or([]), "checkedAt": .string(checkedAt), "rounds": .number(Double(round + 1)),
            ])
            try await updateState(dir) { draft in
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.gate = gate
                if passed { shot.requestedChange = nil }
                draft[screen: id] = shot
                appendLog(&draft, passed ? "\(id) 验收通过" : "\(id) 验收不通过：\(failureReasons.joined(separator: "；"))", passed ? "info" : "warn")
            }
            try await updateRecord(dir) { record in
                record["gate"]?[id] = .obj(["status": gate["status"], "method": "vision", "imageSha256": .string(sha), "reasons": gate["reasons"], "checkedAt": .string(checkedAt)])
                record.append("history", .obj(["at": .string(checkedAt), "event": "gate", "screenId": .string(id), "status": gate["status"], "method": "vision", "reasons": gate["reasons"]]))
            }
            setScreenProgress(dir, id, ["status": .string(passed ? "passed" : round >= limit ? "failed" : "regenerating"), "gateRounds": .number(Double(round + 1))])
            if passed { return gate }
            // limit = 每屏最多自动重生几次（设置里的数字），用完还不通过就交给人处理
            if round >= limit { return gate }
            var screenCtx = ctx
            screenCtx.state = state
            _ = try await generateScreen(screenCtx, id, reason: "验收不通过，重新生成", retryHint: retryHints.isEmpty ? nil : retryHints.joined(separator: "; "))
            round += 1
        }
    }

    func stepGate(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readTypedState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let tokens = forbiddenBrandTokens(softwareName(state), extraTokens(state))
        let tokensHash = gateKey(state)
        let llmAvailable = await resolveLlm("gate") != nil
        let before = progressScreens(dir)
        let screens = plan["screens"].items
        var waiting = JSONObject()
        for screen in screens {
            let id = screen["id"]?.jsString ?? ""
            waiting[id] = (before[id] ?? .emptyObject).merging(["status": "waiting-check"])
        }
        setProgress(dir, .obj(["screens": .object(waiting)]))
        let gates = await mapLimit(screens, 4) { screen, _ in
            do {
                return try await self.gateOne(ctx, screen, tokens, tokensHash, llmAvailable)
            } catch {
                return JSON.obj(["status": "error", "reasons": JSON([messageOf(error)])])
            }
        }
        let failed = screens.indices.filter { ["failed", "error"].contains(gates[$0]["status"]?.string ?? "") }
        let manual = screens.indices.filter { gates[$0]["status"]?.string == "needs-manual" }
        if !failed.isEmpty {
            let detail = failed.map { "\(screens[$0]["id"]?.jsString ?? "")（\(gates[$0]["reasons"].items.map(\.jsString).joined(separator: "；"))）" }.joined(separator: "、")
            throw StudioError("以下截图验收没有通过：\(detail)。可以在截图页重生或换成备选图。")
        }
        if !manual.isEmpty { return StepOutcome(status: .review, message: "请在截图页逐张确认（\(manual.count) 张），确认界面里没有软件名后继续") }
        return StepOutcome(status: .done)
    }
}
