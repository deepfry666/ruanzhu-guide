import StudioCore
import SwiftUI

/// 状态列里的步骤进度。
struct ProgressCell: View {
    let row: ProjectRow

    var body: some View {
        if row.historyReadOnly {
            Text("只有交付包，没有源文件").foregroundStyle(.secondary)
        } else if row.status == "running" {
            let step = row.progress?["step"]?.string ?? row.stepSummary.current
            let index = step.flatMap { STEP_ORDER.firstIndex(of: $0) }.map { $0 + 1 } ?? 1
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("第 \(index) 步 / 共 \(STEP_ORDER.count) 步 · \(step.flatMap { UI_STEP_LABELS[$0] } ?? "准备中")")
                    .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
                ProgressView(value: row.livePercent).tint(Palette.info.color)
            }
        } else {
            let summary = row.stepSummary
            Text("\(summary.done)/\(STEP_ORDER.count)\(summary.current.map { " · \(UI_STEP_LABELS[$0] ?? $0)" } ?? " · 完成")")
                .foregroundStyle(.secondary)
                .help(row.lastError.map { splitDiagnostics($0).text } ?? row.queue?["error"]?.string ?? (summary.current.map { "下一步：\(UI_STEP_LABELS[$0] ?? $0)" } ?? "全部完成"))
        }
    }
}

/// 批量处理：运行中 / 排队 / 完成数量，同时处理几个，暂停、继续。
struct QueueBar: View {
    @State var expanded = false
    @Environment(AppModel.self) var model

    /// 空闲时（没有运行、排队、暂停或需要处理的）不占位置
    static func visible(_ model: AppModel) -> Bool {
        model.batchPaused || model.batchItems.contains { ["running", "queued", "paused", "failed", "needs-attention"].contains($0["status"]?.string ?? "") }
    }

    var body: some View {
        let items = model.batchItems
        if QueueBar.visible(model) {
            let counts = Dictionary(grouping: items, by: { $0["status"]?.string ?? "" }).mapValues(\.count)
            let unfinished = (counts["running"] ?? 0) + (counts["queued"] ?? 0) + (counts["paused"] ?? 0)
            let attention = (counts["failed"] ?? 0) + (counts["needs-attention"] ?? 0)
            VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Text("批量处理").fontWeight(.semibold)
                HStack(spacing: Spacing.xs) {
                    Text("运行中 \(counts["running"] ?? 0) · 排队 \(counts["queued"] ?? 0) · 完成 \(counts["done"] ?? 0)")
                    if attention > 0 { Text("· 需处理 \(attention)").foregroundStyle(Palette.danger) }
                    if let paused = counts["paused"], paused > 0 { Text("· 已暂停 \(paused)") }
                }
                .monospacedDigit()
                HStack(spacing: Spacing.sm) {
                    Text("同时处理")
                    ConcurrencyPicker(value: model.settings.pipeline.batchConcurrency, presets: PROJECT_CONCURRENCY_PRESETS, unit: "个项目") { value in
                        Task {
                            await model.perform { _ = try await model.core?.updateSettings(["pipeline": ["batchConcurrency": .number(Double(value))]]) }
                            await model.reloadSettings()
                        }
                    }
                }
                Spacer()
                if model.batchPaused {
                    Button("继续", systemImage: "play.fill") { Task { await model.core?.batch.resume() } }
                        .buttonStyle(.primary)
                } else if unfinished > 0 {
                    Button("暂停全部", systemImage: "pause.fill") { Task { await model.core?.batch.pause() } }
                        .buttonStyle(.secondary)
                }
                Button(expanded ? "收起详情" : "展开详情", systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                    .buttonStyle(.textAction)
            }
            if expanded {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            let entry = BatchQueueItem(item)
                            let dir = entry.projectDir ?? ""
                            HStack(spacing: Spacing.md) {
                                Text(model.projects.first { $0.dir == dir }?.name ?? Path.basename(dir)).lineLimit(1)
                                Spacer()
                                let status = entry.status?.rawValue ?? ""
                                Text(PROJECT_STATUS[status]?.label ?? QUEUE_LABEL[status] ?? status)
                                    .foregroundStyle(Palette.textSecondary)
                                if let error = entry.error { Text(error).lineLimit(2).foregroundStyle(Palette.danger) }
                            }
                        }
                    }
                }.frame(maxHeight: Metrics.thumbnailList.height * 3)
                Button("清除已完成的记录") { Task { await model.core?.batch.clearFinished() } }.buttonStyle(.textAction)
            }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .surface()
            .onChange(of: model.devQueueExpanded, initial: true) { _, value in expanded = value }
        }
    }
}

/// 首次使用：没有可用的生图线路或没有给规划/文案选模型时，提示先去配置。
struct SetupHint: View {
    @Environment(AppModel.self) var model

    static func missing(_ model: AppModel) -> [(text: String, tab: String)] {
        let providers = model.settings.providers.filter { $0.enabled && (model.providerKeys[$0.id] ?? false) }
        var missing: [(String, String)] = []
        if providers.isEmpty { missing.append(("还没有可用的生图线路（需要启用并填好密钥）", "providers")) }
        if model.settings.llm.assignment("plan") == nil || model.settings.llm.assignment("content") == nil { missing.append(("还没有给「规划界面」和「撰写说明文字」选择大模型", "llm")) }
        return missing
    }

    var body: some View {
        let missing = SetupHint.missing(model)
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "info.circle.fill").foregroundStyle(Palette.info).textStyle(Typography.title)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("开始之前先完成配置").fontWeight(.semibold)
                    ForEach(missing, id: \.tab) { item in
                        HStack(spacing: Spacing.xs) {
                            Text(item.text)
                            Button("去配置") { model.go(.models, tab: item.tab) }.buttonStyle(.link)
                        }
                        .textStyle(Typography.body)
                    }
                    if model.settings.llm.assignment("gate") == nil {
                        Text("检查截图要用看图模型；没有配置时，需要人工逐张确认截图里没有软件名。").textStyle(Typography.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(Spacing.md)
            .surface()
        }
    }
}

/// 更新代码材料的进度条：一个一个处理，显示做到第几个、正在做哪个；做完显示结果，几秒后收起
struct CodeBatchBanner: View {
    let batch: CodeBatchProgress
    let name: (String) -> String

    var body: some View {
        let processed = batch.done + batch.failed
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: batch.finished ? (batch.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "doc.badge.gearshape")
                    .foregroundStyle(batch.finished ? (batch.failed == 0 ? Palette.success.color : Palette.warning.color) : Palette.info.color)
                if batch.finished {
                    Text("代码材料更新完了：成功 \(batch.done) 个\(batch.failed > 0 ? "，没更新 \(batch.failed) 个（列表里标红的，鼠标停上去看原因）" : "")").fontWeight(.medium)
                } else {
                    Text("正在更新代码材料 \(min(processed + 1, batch.total)) / \(batch.total)\(batch.current.map { "：" + name($0) } ?? "")").fontWeight(.medium)
                }
                Spacer()
                if !batch.finished { Text("一个一个处理，每个几秒钟").textStyle(Typography.caption).foregroundStyle(.secondary) }
            }
            ProgressView(value: Double(processed), total: Double(max(batch.total, 1)))
        }
        .padding(Spacing.md)
        .surface(Radius.medium, fill: Palette.info.tint)
    }
}
