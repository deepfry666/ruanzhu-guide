import StudioCore
import SwiftUI

private let ROLE_LABEL = ["primary": "首发", "hedge": "补发", "failover": "切换", "retry": "重试", "probe": "测速", "resume": "续查", "history": "历史导入"]
private let OUTCOME_LABEL = ["winner": "采用", "alternate": "备选", "loser": "被取消", "canceled": "已取消", "timeout": "超时", "job-failed": "整屏失败"]

/// 统计页用的百分位（取最近的一个样本，不插值，和 Electron 版界面一致）。
private func uiPercentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((p / 100 * Double(sorted.count - 1)).rounded(.down)))]
}

struct CallRow: Identifiable {
    let id: Int
    let json: JSON
}

struct CallsView: View {
    @Environment(AppModel.self) private var model
    @State private var provider = ""
    @State private var tab = "image"
    @State private var calls: [JSON] = []
    @State private var llmCalls: [JSON] = []
    /// 失败的大模型调用：点开看模型当时回了什么
    @State private var llmDetail: JSON?

    var rows: [CallRow] {
        calls.filter { $0["role"]?.string != "history" && (provider.isEmpty || $0["providerId"]?.string == provider) }
            .enumerated().map { CallRow(id: $0.offset, json: $0.element) }
    }

    var body: some View {
        let rows = self.rows
        let real = rows.filter { $0.json["kind"]?.string != "aborted" }
        let ok = real.filter { $0.json["ok"].isTruthy }
        let durations = ok.map { ($0.json["durationMs"]?.number ?? 0) / 1000 }
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
                StatTile(title: "生图调用", value: "\(real.count)")
                StatTile(title: "成功率", value: real.isEmpty ? "—" : "\(Int(jsRound(Double(ok.count) / Double(real.count) * 100)))%")
                StatTile(title: "耗时 P50", value: formatSeconds(uiPercentile(durations, 50)))
                StatTile(title: "耗时 P90", value: formatSeconds(uiPercentile(durations, 90)))
                StatTile(title: "补发 / 补发胜出", value: "\(rows.filter { $0.json["role"]?.string == "hedge" }.count) / \(rows.filter { $0.json["role"]?.string == "hedge" && $0.json["outcome"]?.string == "winner" }.count)")
                StatTile(title: "备选图", value: "\(rows.filter { $0.json["outcome"]?.string == "alternate" }.count)")
            }
            HStack(spacing: Spacing.md) {
                SegmentedTabs(
                    selection: $tab,
                    items: [
                        .init(value: "image", title: "生图"),
                        .init(value: "llm", title: "大模型"),
                    ]
                )
                Spacer()
                HStack(spacing: Spacing.sm) {
                    Text("线路").textStyle(Typography.captionStrong).foregroundStyle(Palette.textSecondary)
                    Picker("线路", selection: $provider) {
                        Text("全部线路").tag("")
                        ForEach(model.settings.providers) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            Group {
                if tab == "image" { imageTable(rows) } else { llmTable }
            }
            .clipShape(Radius.shape(Radius.large))
            .overlay(Radius.shape(Radius.large).strokeBorder(Palette.divider, lineWidth: Palette.hairline))
        }
        .padding(Spacing.xl)
        .task(id: model.callsRevision) { reload() }
    }

    func reload() {
        calls = model.core?.queryCalls(limit: 2000) ?? []
        llmCalls = model.core?.queryLlmCalls(limit: 500) ?? []
    }

    func imageTable(_ rows: [CallRow]) -> some View {
        Table(rows) {
            TableColumn("时间") { row in Text(formatTime(row.json["ts"]?.string)).textStyle(Typography.body.number) }.width(90)
            TableColumn("项目 / 屏") { row in
                HStack(spacing: Spacing.xs) {
                    Text(row.json["projectName"]?.string ?? "—").textStyle(Typography.body).lineLimit(1)
                    Text(row.json["screenId"]?.string ?? "").font(Typography.caption.font.monospaced()).foregroundStyle(Palette.textSecondary)
                }
                .help("\(row.json["projectName"]?.string ?? "") \(row.json["screenId"]?.string ?? "")")
            }
            .width(min: 150)
            TableColumn("线路") { row in Text(row.json["providerName"]?.string ?? row.json["providerId"].text).textStyle(Typography.body).lineLimit(1).help(row.json["providerName"]?.string ?? "") }.width(min: 90, ideal: 130)
            TableColumn("类型") { row in Text(ROLE_LABEL[row.json["role"]?.string ?? ""] ?? row.json["role"]?.string ?? "—").textStyle(Typography.body) }.width(56)
            TableColumn("尺寸") { row in Text(row.json["requestSize"]?.string ?? "—").font(Typography.body.font.monospaced()) }.width(80)
            TableColumn("耗时") { row in Text(formatSeconds(row.json["durationMs"]?.number.map { $0 / 1000 })).textStyle(Typography.body.number) }.width(70)
            TableColumn("结果") { row in
                if row.json["ok"].isTruthy {
                    let outcome = row.json["outcome"]?.string ?? ""
                    TagView(text: OUTCOME_LABEL[outcome] ?? "成功", tone: outcome == "alternate" ? .blue : .green)
                } else if row.json["kind"]?.string == "aborted" {
                    TagView(text: OUTCOME_LABEL[row.json["outcome"]?.string ?? ""] ?? "已取消")
                } else {
                    Text("\(row.json["kind"].text)：\(row.json["errorMessage"].text)").textStyle(Typography.body).foregroundStyle(Palette.danger).lineLimit(1).help(row.json["errorMessage"].text)
                }
            }
            .width(min: 64, ideal: 100)
        }
    }

    var llmTable: some View {
        Table(llmCalls.enumerated().map { CallRow(id: $0.offset, json: $0.element) }) {
            TableColumn("时间") { row in Text(formatTime(row.json["ts"]?.string)).textStyle(Typography.body.number) }.width(90)
            TableColumn("步骤") { row in Text(LLM_STEPS[row.json["step"]?.string ?? ""]?.label ?? row.json["step"].text).textStyle(Typography.body) }.width(min: 100, ideal: 140)
            TableColumn("模型") { row in Text(row.json["model"].text).textStyle(Typography.body) }.width(min: 120, ideal: 200)
            TableColumn("耗时") { row in Text(formatSeconds(row.json["durationMs"]?.number.map { $0 / 1000 })).textStyle(Typography.body.number) }.width(70)
            TableColumn("结果") { row in
                if row.json["ok"].isTruthy { TagView(text: "成功", tone: .green) } else {
                    HStack(spacing: Spacing.sm) {
                        Text(row.json["errorMessage"].text).textStyle(Typography.body).foregroundStyle(Palette.danger).lineLimit(1).help(row.json["errorMessage"].text)
                        Button("详情") { llmDetail = row.json }.buttonStyle(.textAction)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { llmDetail != nil }, set: { if !$0 { llmDetail = nil } })) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("「\(LLM_STEPS[llmDetail?["step"]?.string ?? ""]?.label ?? llmDetail?["step"].text ?? "")」失败")
                    .textStyle(Typography.title).foregroundStyle(Palette.text)
                Text(llmDetail?["errorMessage"].text ?? "")
                    .textStyle(Typography.body).foregroundStyle(Palette.text).textSelection(.enabled)
                Text("模型当时回的内容（摘录）")
                    .textStyle(Typography.bodyStrong).foregroundStyle(Palette.text)
                ScrollView {
                    Text(llmDetail?["errorDetail"]?.string ?? "这次失败没有记下模型回的内容（1.6.2 以前的记录，或者请求没到模型那一步就失败了）。")
                        .font(Typography.body.font.monospaced())
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Spacing.md)
                .surface(Radius.medium, fill: Palette.windowBackground)
                .frame(minWidth: 620, minHeight: 320)
                HStack { Spacer(); Button("好") { llmDetail = nil }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
            }
            .padding(Spacing.xl)
            .background(Palette.card)
            .designSystem()
        }
    }
}
