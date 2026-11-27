import Foundation

extension Pipeline {
    // MARK: - S5 文案

    func stepContent(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let settings = ctx.settings
        let state = try readTypedState(dir)
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        let paths = projectPaths(dir)
        let floor = max(300, settings.pipeline.featureTextFloor == 0 ? 300 : settings.pipeline.featureTextFloor)
        let name = softwareName(state)
        let existing = try FS.readJSON(paths.content)
        var existingById: [String: JSON] = [:]
        var existingOrder: [String] = []
        for (index, screen) in (existing?["screens"].items ?? []).enumerated() {
            let id = screen["id"].or(.string(screenId(index))).jsString
            if existingById[id] == nil { existingOrder.append(id) }
            existingById[id] = screen
        }
        let planScreens = plan["screens"].items
        let contentDateJson = state.request?.contentDate.map(JSON.string)
        let planHash = hashObject(.obj(["contentDate": contentDateJson, "earliestDate": JSON.maybe(explicitEarliestDate(state)), "profile": plan["profile"] ?? .null, "titles": .array(planScreens.map { $0["title"] ?? .null })]))
        let neutral = !softwareNameNamesPlatform(name)
        var autoInstructions: [String: String] = [:]
        var inventories: [String: String] = [:]
        var targets: [JSON] = []
        var staleEdited: [String] = []
        var contentHashes: [(String, String)] = []
        for screen in planScreens {
            let id = screen["id"]?.jsString ?? ""
            let gate = state[screen: id]?.gate
            if let inventory = gate?["inventory"].truthyValue { inventories[id] = inventory.jsString }
            let hash = hashObject(.obj([
                "title": screen["title"], "contract": screen["textContract"], "mustShow": screen["mustShow"], "sampleData": screen["sampleData"],
                "inventory": inventories[id].map(JSON.string) ?? .null,
                "contentDate": contentDateJson,
                "earliestDate": JSON.maybe(explicitEarliestDate(state)),
            ]))
            contentHashes.append((id, hash))
            let old = existingById[id]
            let shot = state[screen: id]
            let forced = (ctx.forceContent?.contains(id) ?? false) || !(ctx.contentInstructions?[id] ?? "").isEmpty
            let existingContentHash = shot?.contentHash ?? ""
            let unchanged = !existingContentHash.isEmpty ? existingContentHash == hash : state.origin == "imported"
            var keep = old?["text"].isTruthy == true && !forced && (shot?.textEdited == true || (unchanged && shot?.contentStale != true))
            // 软件名没指明系统，旧说明里却有 iPhone、安卓 等字样：只改掉这些字样，其余保持
            let platformHits = keep && neutral ? findPlatformTerms([old?["title"].text ?? "", old?["caption"].text ?? "", old?["text"].text ?? ""]) : []
            if !platformHits.isEmpty {
                keep = false
                autoInstructions[id] = platformFixInstruction(platformHits)
            }
            if !keep { targets.append(screen) }
            if keep, shot?.textEdited == true, shot?.contentStale == true { staleEdited.append(id) }
        }
        let existingOverviewValue = existing?["cover"]?["overview"]
        let overviewHits = neutral ? findPlatformTerms([existingOverviewValue.text]) : []
        if !overviewHits.isEmpty { autoInstructions["overview"] = platformFixInstruction(overviewHits) }
        // 用户自己的修改要求优先；自动去系统字样的要求只补在没有要求的部分
        let instructions = (ctx.contentInstructions ?? [:]).merging(autoInstructions) { user, auto in user.isEmpty ? auto : user }
        if !autoInstructions.isEmpty {
            try await log(dir, "说明里出现了系统或设备字样，改成通用说法：\(autoInstructions.keys.sorted().map { $0 == "overview" ? "封面介绍" : $0 }.joined(separator: "、"))")
        }
        let savedPlanHash = state.contentPlanHash ?? ""
        let needOverview = !existingOverviewValue.isTruthy
            || (!savedPlanHash.isEmpty && savedPlanHash != planHash && state.overviewEdited != true)
            || (ctx.forceContent?.contains("overview") ?? false)
            || !(instructions["overview"] ?? "").isEmpty
        var currentTexts: [String: String] = [:]
        for (id, screen) in existingById { currentTexts[id] = screen["text"].text }
        var written: [String: JSON] = [:]
        var overview = existingOverviewValue.text
        if !targets.isEmpty || needOverview {
            try await log(dir, "正在撰写 \(targets.count) 屏说明\(needOverview ? "和封面介绍" : "")…")
            var chunks: [[JSON]] = stride(from: 0, to: targets.count, by: 4).map { Array(targets[$0..<min($0 + 4, targets.count)]) }
            if chunks.isEmpty { chunks.append([]) }
            for (index, chunk) in chunks.enumerated() {
                let wantsOverview = needOverview && index == 0
                // 截图里本来就有的日期，正文照实描述不算违规（人工确认过的截图也可能带着）
                let shownDates = dateKeys(chunk.flatMap { state[screen: $0["id"]?.jsString ?? ""]?.gate?["visibleText"].items.map(\.jsString) ?? [] }, base: contentDateOf(state))
                // 每屏截图上抄下的文字加示例数据：说明里的数字要能在这里找到
                var shownTexts: [String: [String]] = [:]
                for screen in chunk {
                    let id = screen["id"]?.jsString ?? ""
                    let visible = state[screen: id]?.gate?["visibleText"].items.map(\.jsString) ?? []
                    if !visible.isEmpty { shownTexts[id] = visible + screen["sampleData"].items.map(\.jsString) }
                }
                let shown = shownTexts
                setProgress(dir, .obj(["detail": .string(targets.isEmpty ? "撰写封面介绍" : "撰写说明：第 \(min(targets.count, index * 4 + 1))–\(min(targets.count, index * 4 + chunk.count)) 屏（共 \(targets.count) 屏）")]))
                let result = try await callLlm("content", dir, ChatJsonRequest(
                    system: CONTENT_SYSTEM.replacingOccurrences(of: "{floor}", with: String(floor)),
                    user: contentUserPrompt(softwareName: softwareName(state), profile: plan["profile"], screens: chunk, inventories: inventories, needOverview: wantsOverview, existingOverview: overview, floor: floor, instructions: instructions, currentTexts: currentTexts) + platformNeutralRule(softwareName(state)) + contentDateRule(state) + CONTENT_VISIBLE_RULE + CONTENT_STYLE_RULE + RED_LINE_RULE,
                    schema: CONTENT_SCHEMA,
                    check: { contentCheck($0, screens: chunk, needOverview: wantsOverview, floor: floor) + platformProblems(name, "封面介绍或功能说明", [$0["overview"].text] + $0["screens"].items.flatMap { [$0["title"].text, $0["text"].text] }) },
                    softCheck: {
                        let texts = [$0["overview"].text] + $0["screens"].items.flatMap { [$0["title"].text, $0["text"].text] }
                        return dateProblems(state, "封面介绍或功能说明", texts, allowed: shownDates) + redLineProblems("封面介绍或功能说明", texts) + contentStyleProblems($0["screens"].items)
                            + unshownNumberProblems($0["screens"].items, shown: shown)
                            + trafficCodeProblems(AppProfile(state.appProfile), "功能说明", texts)
                    },
                    temperature: 0.7,
                    maxTokens: 8000
                ))
                if wantsOverview { overview = (result["overview"]?.jsString ?? "undefined").jsTrimmed }
                for item in result["screens"].items { written[item["id"]?.jsString ?? ""] = item }
            }
        }
        let existingScreens = existing?["screens"].items ?? []
        let sameScreens = existing != nil && existingScreens.count == planScreens.count && planScreens.enumerated().allSatisfy { index, screen in
            existingScreens[index]["id"].or(.string(screenId(index))).jsString == screen["id"]?.jsString && existingScreens[index]["title"].isTruthy
        }
        let staleList = staleEdited
        let hashes = contentHashes
        let recordStaleWarning: @Sendable (inout ProjectState) -> Void = { draft in
            var warnings = draft.warnings.items.filter { !($0.string ?? "").hasPrefix("截图已更换") }
            if !staleList.isEmpty { warnings.append(.string("截图已更换，但这些屏的说明是人工改过的，没有自动重写，请检查是否还和新截图一致：\(staleList.joined(separator: "、"))")) }
            draft.warnings = .array(warnings)
        }
        if existing != nil, sameScreens, targets.isEmpty, !needOverview {
            try await updateState(dir) { draft in
                for (id, hash) in hashes {
                    var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                    shot.contentHash = hash
                    shot.contentStale = staleList.contains(id)
                    draft[screen: id] = shot
                }
                draft.contentPlanHash = planHash
                recordStaleWarning(&draft)
            }
            return StepOutcome(status: .done)
        }
        let featureMap = plan["featureMap"].or(.emptyObject)
        let regenerated = planScreens.contains { !(state[screen: $0["id"]?.jsString ?? ""]?.providerId ?? "").isEmpty }
        var content = existing ?? .emptyObject
        let request = state.request
        content["softwareName"] = request?.softwareName.map(JSON.string)
        content["versionPolicy"] = request?.versionPolicy.map(JSON.string)
        if request?.versionPolicy == "separate-metadata", let version = request?.applicableVersion, !version.isEmpty { content["applicableVersion"] = .string(version) }
        content["createdAt"] = request?.createdAt.map(JSON.string)
        content["screenshotCount"] = .number(Double(planScreens.count))
        content["screenCountReason"] = featureMap["coverageReason"].truthyValue ?? existing?["screenCountReason"]
        content["featureTier"] = 300
        content["imageRoute"] = regenerated || !(existing?["imageRoute"].isTruthy ?? false) ? "image-gateway" : existing!["imageRoute"]!
        // 被大模型改写掉的旧文字记进历史，可以在文案页找回
        var replaced: [ContentVersion] = []
        let previousOverview = existingOverviewValue.text
        if !previousOverview.isEmpty, overview != previousOverview { replaced.append(ContentVersion(target: "overview", text: previousOverview, source: "AI 重写前")) }
        for (id, fresh) in written {
            let previousText = existingById[id]?["text"].text ?? ""
            if !previousText.isEmpty, fresh["text"].text.jsTrimmed != previousText.jsTrimmed {
                replaced.append(ContentVersion(target: id, title: existingById[id]?["title"].text, text: previousText, source: "AI 重写前"))
            }
        }
        recordContentHistory(dir, replaced)
        content["cover"] = (existing?["cover"].or(.emptyObject) ?? .emptyObject).merging(.obj(["overview": .string(overview)]))
        content["screens"] = .array(planScreens.enumerated().map { index, screen in
            let id = screen["id"]?.jsString ?? ""
            let old = existingById[id] ?? .emptyObject
            let fresh = written[id]
            let shot = state[screen: id]
            let title = (fresh?["title"].truthyValue ?? old["title"].truthyValue ?? screen["title"] ?? .null).jsString.jsTrimmed
            let imageSize: JSON? = (shot?.width ?? 0) != 0 ? .string("\(shot!.width!)x\(shot?.height.map(String.init) ?? "undefined")") : old["image_size"]
            return .obj([
                "id": .string(id),
                "title": .string(title),
                "caption": .string("图\(index + 1) \(title)"),
                "image": .string("screens/\(id).png"),
                "image_size": imageSize,
                "text_anchor": screen["textContract"]?["entry"].truthyValue ?? .string(title),
                "summary": .string(title),
                "text": .string((fresh?["text"].truthyValue ?? old["text"].truthyValue ?? "").jsString.jsTrimmed),
            ])
        })
        content["screenshotReview"] = nil
        try FS.writeJSONAtomic(paths.content, content)
        let writtenIds = Set(written.keys)
        let missing = planScreens.compactMap { screen -> String? in
            let id = screen["id"]?.jsString ?? ""
            return inventories[id] == nil ? id : nil
        }
        try await updateState(dir) { draft in
            for (id, hash) in hashes {
                var shot = draft[screen: id] ?? ScreenState(.emptyObject)
                shot.contentHash = hash
                shot.contentStale = staleList.contains(id)
                if writtenIds.contains(id) { shot.textEdited = false }
                draft[screen: id] = shot
            }
            draft.contentPlanHash = planHash
            recordStaleWarning(&draft)
            var warnings = draft.warnings.items.filter { !($0.string ?? "").hasPrefix("文案未按截图对账") }
            if !missing.isEmpty, !writtenIds.isEmpty { warnings.append(.string("文案未按截图对账：\(missing.joined(separator: "、"))（没有看图模型的抄录结果）")) }
            draft.warnings = .array(warnings)
        }
        return StepOutcome(status: .done)
    }

    // MARK: - S6 设计说明

    func stepDesign(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readTypedState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        if state.request?.wantDesign != true {
            if content["design"] != nil {
                content["design"] = nil
                try FS.writeJSONAtomic(paths.content, content)
            }
            return StepOutcome(status: .skipped)
        }
        let designName = softwareName(state)
        let designHits = softwareNameNamesPlatform(designName) ? [] : findPlatformTerms(content["design"]?["sections"].items.flatMap { [$0["title"].text, $0["text"].text] } ?? [])
        let designInstruction = (ctx.designInstruction ?? "").isEmpty && !designHits.isEmpty ? platformFixInstruction(designHits) : ctx.designInstruction
        let hasContentDate = !(state.request?.contentDate ?? "").isEmpty
        let designDatesCurrent = !hasContentDate
            || (content["designContentDate"]?.string == contentDateOf(state) && content["designEarliestDate"]?.string == explicitEarliestDate(state))
        if !(content["design"]?["sections"]?.array?.isEmpty ?? true), designDatesCurrent, !ctx.forceDesign, (designInstruction ?? "").isEmpty { return StepOutcome(status: .done) }
        guard let plan = try readPlan(dir) else { throw StudioError("还没有界面规划") }
        try await log(dir, "正在撰写设计说明…")
        let name = softwareName(state)
        let current = (content["design"]?["sections"].items ?? []).map { "\(templateText($0["title"]))\n\(templateText($0["text"]))" }.joined(separator: "\n\n")
        let result = try await callLlm("design", dir, ChatJsonRequest(
            system: DESIGN_SYSTEM,
            user: designUserPrompt(softwareName: softwareName(state), profile: plan["profile"], features: plan["featureMap"]?["features"].items ?? [], screens: plan["screens"].items, instruction: designInstruction, current: current) + platformNeutralRule(softwareName(state)) + contentDateRule(state) + RED_LINE_RULE,
            schema: DESIGN_SCHEMA,
            check: { designCheck($0) + platformProblems(name, "设计说明", $0["sections"].items.flatMap { [$0["title"].text, $0["text"].text] }) },
            softCheck: { redLineProblems("设计说明", $0["sections"].items.flatMap { [$0["title"].text, $0["text"].text] }) },
            temperature: 0.6,
            maxTokens: 8000
        ))
        // 被大模型改写掉的旧设计说明记进历史
        let oldSections = content["design"]?["sections"].items ?? []
        recordContentHistory(dir, oldSections.enumerated().map { index, section in
            ContentVersion(target: "design-\(index + 1)", title: section["title"].text, text: section["text"].text, source: "AI 重写前")
        })
        content["designContentDate"] = .string(contentDateOf(state))
        content["designEarliestDate"] = JSON.maybe(explicitEarliestDate(state))
        content["design"] = .obj(["sections": .array(result["sections"].items.map { .obj(["title": .string($0["title"]?.jsString.jsTrimmed ?? ""), "text": .string($0["text"]?.jsString.jsTrimmed ?? "")]) })])
        try FS.writeJSONAtomic(paths.content, content)
        return StepOutcome(status: .done)
    }

    // MARK: - S7 回执

    func stepReceipt(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let state = try readTypedState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content) else { throw StudioError("还没有文案") }
        let tokensHash = gateKey(state)
        var reviewed: [JSON] = []
        var pending: [String] = []
        for index in 0..<content["screens"].items.count {
            let id = screenId(index)
            let sha = try sha256File(paths.screenFile(id))
            let gate = state[screen: id]?.gate
            let ok = gate.isTruthy && gate?["sha"]?.string == sha && ["passed", "manual-passed"].contains(gate?["status"]?.string ?? "")
                && (gate?["tokensHash"]?.string == tokensHash || gate?["method"]?.string == "imported-receipt")
            if !ok { pending.append(id) }
            reviewed.append(.obj(["screenId": .string(id), "image": .string("screens/\(id).png"), "sha256": .string(sha)]))
        }
        if !pending.isEmpty { throw StudioError("这些截图还没有通过验收（或验收后图片被替换）：\(pending.joined(separator: "、"))") }
        let existing = content["screenshotReview"]
        let existingScreens = existing?["reviewedScreens"]?.array
        let sameReview = existing?["status"]?.string == "passed" && existingScreens?.count == reviewed.count && reviewed.enumerated().allSatisfy { index, item in
            let old = existingScreens?[index] ?? .emptyObject
            return old["screenId"] == item["screenId"] && old["image"] == item["image"] && old["sha256"] == item["sha256"]
        }
        if !sameReview {
            content["screenshotReview"] = .obj(["status": "passed", "reviewedScreens": .array(reviewed)])
            try FS.writeJSONAtomic(paths.content, content)
        }
        return StepOutcome(status: .done)
    }

    // MARK: - S8 构建

    func stepBuild(_ ctx: StepContext) async throws -> StepOutcome {
        let dir = ctx.projectDir
        let settings = ctx.settings
        let state = try readTypedState(dir)
        let paths = projectPaths(dir)
        guard var content = try FS.readJSON(paths.content), content["screenshotReview"].isTruthy else { throw StudioError("没有审查回执，不能构建") }
        let name = softwareName(state)
        let request = state.request
        let hasCodeDoc = FS.exists(Path.join(paths.bundle(name), "\(name)指南_代码-（JAVA）.docx"))
        let codeSource = codeSourceFor(state, settings).source
        let codePath = codeSource?["path"]?.string ?? ""
        if codePath.isEmpty, hasCodeDoc, request?.allowDropCodeDoc != true {
            throw StudioError("现有交付包里有代码文档，但这个项目没有代码来源，重建后新交付包将不含代码文档（旧交付包会先归档）。请在「交付」里点「改用总设置的代码来源」或「确认不含代码文档」后再继续。")
        }
        if !codePath.isEmpty, !FS.exists(codePath) { throw StudioError("代码来源不存在：\(codePath)（在「设置 → 代码来源」里重新选择）") }
        // 交付包里的 Word / TXT 在软件外改过（比如在 WPS 里手改）：不再停下来问，
        // 手改过的文件另存一份（不参与「旧交付包只留最近 3 份」的清理），再用软件里的内容覆盖
        let edited = externallyEditedFiles(dir, state)
        if !edited.isEmpty {
            let keep = Path.join(paths.archive, "\(name)-手改保留-\(timestampSlug())")
            try FS.mkdirp(keep)
            for file in edited { try FS.copy(Path.join(paths.bundle(name), file), Path.join(keep, file)) }
            try await log(dir, "已把在软件外改过的文件另存到归档：\(Path.basename(keep))")
        }
        let fontPlan = resolveFontPlan(settings.pdf)
        content["softwareName"] = .string(name)
        let compileDateOverride = request?.compileDate ?? ""
        content["compileDate"] = .string(!compileDateOverride.isEmpty ? compileDateOverride : contentDateChinese(contentDateOf(state)))
        content["contentDate"] = .string(contentDateOf(state))
        content["earliestDate"] = JSON.maybe(explicitEarliestDate(state))
        content["compileDateOverride"] = .string(compileDateOverride)
        content["screens"] = .array(content["screens"].items.enumerated().map { index, screen in screen.merging(.obj(["image": .string("screens/\(screenId(index)).png")])) })
        var txtFields = settings.txtFields
        for (key, value) in request?.txtFields.fields ?? JSONObject() { txtFields[key] = value.jsString }
        let languageOverride = request?.txtFields?["language"].isTruthy ?? false
        let record = readRecord(dir)
        var provenanceScreens = JSONObject()
        for index in 0..<content["screens"].items.count {
            let id = screenId(index)
            let entry: JSON = record?["screens"]?[id] ?? .emptyObject
            let gate: JSON = state[screen: id]?.gate ?? .emptyObject
            let fallbackSource: JSON = .string(state.origin == "imported" ? "imported-from-skill" : "unknown")
            var item = JSONObject()
            item["source"] = entry["source"].or(fallbackSource)
            item["provider"] = entry["providerName"].or(entry["providerId"].or(.null))
            item["model"] = entry["model"].or(.null)
            item["generatedAt"] = entry["generatedAt"].or(.null)
            item["hedged"] = entry["hedged"].or(false)
            item["gate"] = gate["method"].or(.null)
            provenanceScreens[id] = .object(item)
        }
        let provenance: JSON = .obj([
            "builtBy": .string("软件指南生成器\(appVersion.isEmpty ? "" : " \(appVersion)")"),
            "recordFile": record != nil ? "generation-record.json" : .null,
            "screens": .object(provenanceScreens),
            "llm": record?["llm"].truthyValue ?? .emptyObject,
        ])
        let input = BuildInput(
            projectDir: dir, softwareName: name, content: content, codeSource: codeSource, txtFields: txtFields, languageOverride: languageOverride,
            excludeDirs: settings.codeDefaults.excludeDirs, floor: max(300, settings.pipeline.featureTextFloor == 0 ? 300 : settings.pipeline.featureTextFloor),
            extraBrandTokens: extraTokens(state), stagingRoot: projectStore.stagingRoot, provenance: provenance, fontPlan: fontPlan, preserveContent: ctx.bundleOnly
        )
        let result = try await buildBundle(input) { message in
            self.setProgress(dir, .obj(["detail": .string(message)]))
            try? await self.log(dir, message)
        }
        let built = BuildRecord(result)
        let at = isoNow()
        let hashes = bundleHashes(dir, name)
        try await updateState(dir) { draft in
            if !edited.isEmpty { draft.bundleUpdateNotice = "交付包里有手改过的文件，已另存到归档后更新" }
            draft.lastBuild = BuildRecord(JSON.obj(["at": .string(at), "bundleHashes": hashes]).merging(result))
            draft.overwriteExternalEdits = nil
            // 记下这次用的代码来源：以后改总设置，已完成的项目不受影响
            if !ctx.bundleOnly || draft.bundleRevision == state.bundleRevision {
                var req = draft.request ?? ProjectRequest(.emptyObject)
                req.codeSource = codeSource ?? .null
                req.codeSourceLocked = true
                draft.request = req
            }
            var warnings = draft.warnings.items.filter { !($0.string ?? "").hasPrefix("构建：") }
            for warning in built.warnings.items { warnings.append(.string("构建：\(warning.jsString)")) }
            if built.withCode != true { warnings.append("构建：没有代码来源，本次没有生成代码文档（在「设置 → 代码来源」里设置）") }
            draft.warnings = .array(warnings)
            appendLog(&draft, "交付包已生成：\(jsJoin(built.files.items, "、"))")
        }
        let usedAt = isoNow()
        try await updateRecord(dir) { record in
            record.append("history", .obj([
                "at": .string(isoNow()), "event": "build", "files": built.files, "withPdf": built.withPdf.map(JSON.bool), "withCode": built.withCode.map(JSON.bool),
                "codeLines": built.code?["lineCount"] ?? .null, "codeSource": JSON.orNull(codePath.isEmpty ? nil : codePath), "codeSha256": built.codeSha256.map(JSON.string) ?? .null, "pdfFonts": built.pdfFonts,
            ]))
            record["codeSource"] = codePath.isEmpty ? .null : .obj([
                "path": .string(codePath), "extensions": codeSource?["extensions"], "fileCount": built.code?["fileCount"],
                "lineCount": built.code?["lineCount"], "sha256": built.codeSha256.map(JSON.string) ?? .null, "usedAt": .string(usedAt),
            ])
        }
        return StepOutcome(status: .done)
    }

    // MARK: - 输入哈希

    func stepInputHash(_ step: PipelineStepName, _ dir: String, _ state: ProjectState, _ settings: Settings) -> String? {
        let paths = projectPaths(dir)
        let request = state.request
        let platform = platformOf(state, settings)
        switch step {
        case .plan:
            // 不含软件名：改名不应触发重新规划（需要时可以手动强制重新规划）
            return hashObject(.obj(["screenCount": request?.raw["screenCount"], "emphasis": request?.emphasis.map(JSON.string), "notes": request?.notes.map(JSON.string), "platform": .string(platform)]))
        case .prompts:
            let plan = FS.readJSONQuiet(paths.screenPlan)
            let ui = FS.readJSONQuiet(paths.uiContract)
            var edited = JSONObject()
            for id in state.screens.fields.keys { edited[id] = .bool(state[screen: id]?.promptEdited == true) }
            return hashObject(.obj(["plan": plan?["screens"].truthyValue ?? .null, "ui": ui ?? .null, "platform": .string(platform), "target": .string(settings.image.targetSize), "edited": .object(edited)]))
        case .build:
            let content = FS.readJSONQuiet(paths.content)
            var shas = JSONObject()
            for id in state.screens.fields.keys {
                let screen = state[screen: id]
                if let sha = screen?.imageSha, !sha.isEmpty { shas[id] = .string(sha) }
                else if let sha = screen?.gate?["sha"] { shas[id] = sha }
            }
            var txt = JSONObject()
            // 源程序量是 1.6.0 新加的字段：还是默认值时不进哈希，免得所有旧项目都被当成要重建交付包
            for (key, value) in settings.txtFields.sorted(by: { $0.key < $1.key }) where !(key == "sourceLines" && value == DEFAULT_TXT_FIELDS["sourceLines"]) { txt[key] = .string(value) }
            for (key, value) in request?.txtFields.fields ?? JSONObject() { txt[key] = value }
            let hasContentDate = !(request?.contentDate ?? "").isEmpty
            return hashObject(.obj([
                "content": content ?? .null, "shas": .object(shas), "code": codeSourceFor(state, settings).source ?? .null,
                "contentDate": request?.contentDate.map(JSON.string), "earliestDate": JSON.maybe(explicitEarliestDate(state)), "compileDate": hasContentDate ? request?.compileDate.map(JSON.string) : nil,
                "txt": .object(txt), "name": request?.softwareName.map(JSON.string), "bundle": .bool(FS.exists(paths.bundle(softwareName(state)))),
            ]))
        default:
            return nil // 其余步骤内部自行增量判断
        }
    }

    func stepInputHash(_ step: String, _ dir: String, _ state: JSON, _ settings: Settings) -> String? {
        stepInputHash(PipelineStepName(rawValue: step), dir, ProjectState(state), settings)
    }
}
