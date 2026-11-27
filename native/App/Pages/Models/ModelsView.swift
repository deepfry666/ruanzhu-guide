import StudioCore
import SwiftUI

/// 生图线路、大模型、调用记录放在一起：都是「生成用到的服务」，和软件本身的设置分开。
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    private var activeTab: String {
        ["providers", "llm", "calls"].contains(model.modelsTab) ? model.modelsTab : "providers"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.lg) {
                Text("模型与线路").textStyle(Typography.title).foregroundStyle(Palette.text)
                Spacer()
                SegmentedTabs(
                    selection: Binding(get: { activeTab }, set: { model.modelsTab = $0 }),
                    items: [
                        .init(value: "providers", title: "生图线路"),
                        .init(value: "llm", title: "大模型"),
                        .init(value: "calls", title: "调用记录"),
                    ]
                )
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)
            .frame(height: Metrics.toolbarHeight)
            Rectangle().fill(Palette.divider).frame(height: Palette.hairline)
            Group {
                switch activeTab {
                case "llm": LlmView()
                case "calls": CallsView()
                default: ProvidersView()
                }
            }
        }
        .background(Palette.windowBackground)
        .navigationTitle("模型与线路")
    }
}

struct ProbeState: Identifiable {
    let id = UUID()
    let providerName: String
    var report: JSON?
}

struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var statuses: [String: JSON] = [:]
    @State private var editing: ImageProvider?
    @State private var probe: ProbeState?
    @State private var realProbe: ImageProvider?
    @State private var deleting: ImageProvider?

    var providers: [ImageProvider] { model.settings.providers }

    var body: some View {
        PageScroll {
            SettingsGroup(
                title: "线路（按顺序优先使用）",
                trailing: AnyView(
                    Button { editing = newProviderFromPreset("openai-sync", id: "", name: "") } label: {
                        Label("添加线路", systemImage: "plus")
                    }
                    .buttonStyle(.primary)
                    .help("添加线路")
                )
            ) {
                if providers.isEmpty {
                    Text("还没有线路。点「添加线路」开始配置。")
                        .textStyle(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Spacing.lg)
                } else {
                    providerHeader
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        providerRow(index, provider)
                    }
                }
            }
            StrategyGroups()
        }
        .task(id: model.callsRevision) { await reloadStatuses() }
        .task(id: model.settingsRevision) { await reloadStatuses() }
        .sheet(item: $editing) { provider in
            ProviderEditor(provider: provider, hasKey: model.providerKeys[provider.id] ?? false) {
                editing = nil
                Task { await reloadAll() }
            }
            .environment(model).designSystem()
            .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        }
        .sheet(item: $probe) { state in
            ProbeSheet(state: state).designSystem()
        }
        .confirmationDialog("真实生成一张测速？", isPresented: Binding(get: { realProbe != nil }, set: { if !$0 { realProbe = nil } }), titleVisibility: .visible) {
            Button("开始测速") { if let provider = realProbe { runProbe(provider, real: true) } }
        } message: {
            Text("会扣这条线路一张低质量图的费用，结果会计入耗时统计，测速成功也会解除冷却和熔断。")
        }
        .confirmationDialog(deleting.map { "删除线路「\($0.name)」？" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let provider = deleting else { return }
                Task {
                    await model.perform { try await model.core?.deleteProvider(provider.id) }
                    await reloadAll()
                }
            }
        } message: {
            Text("密钥也会一起删除。")
        }
    }

    var providerHeader: some View {
        HStack(spacing: Spacing.md) {
            Text("顺序").frame(width: 48, alignment: .leading)
            Text("线路").frame(maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: 112, alignment: .leading)
            Text("耗时 P50 / P90").frame(width: 108, alignment: .leading).help("最近 50 次成功调用")
            Text("成功率").frame(width: 56, alignment: .leading)
            Text("补发线").frame(width: 60, alignment: .leading).help("超过这个时间还没出图就补发到另一条线路；有 5 次以上历史后按实际耗时自动计算")
            Text("并发").frame(width: 36, alignment: .leading)
            Text("启用").frame(width: 44, alignment: .leading)
            Text("").frame(width: 112)
        }
        .textStyle(Typography.captionStrong)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    func providerRow(_ index: Int, _ provider: ImageProvider) -> some View {
        let status = statuses[provider.id] ?? .emptyObject
        let isAsync = PROVIDER_PRESETS[provider.preset]?.protocol == "async"
        return HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == providers.count - 1)
            }
            .buttonStyle(.iconAction)
            .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(provider.name).textStyle(Typography.bodyStrong).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle).help(provider.name)
                Text("\(provider.model) · \(isAsync ? "异步" : "同步") · \(provider.sizeMode == "ratio" ? "比例" : provider.pixelSize)")
                    .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if !provider.enabled {
                    TagView(text: "已停用")
                } else if !(model.providerKeys[provider.id] ?? false) {
                    TagView(text: "没有密钥", tone: .red).help("编辑这条线路，填好密钥后才能用")
                } else if let reason = status["unavailable"]?.string {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        TagView(text: reason.components(separatedBy: "：").first ?? reason, tone: .orange).help(reason)
                        Button("手动恢复") {
                            Task {
                                await model.core?.resetProviderHealth(provider.id)
                                await reloadStatuses()
                            }
                        }
                        .buttonStyle(.textAction)
                    }
                } else {
                    TagView(text: "可用", tone: .green)
                }
            }
            .frame(width: 112, alignment: .leading)
            Text(status["p50"]?.number.map { "\(formatSeconds($0)) / \(formatSeconds(status["p90"]?.number))" } ?? "—")
                .textStyle(Typography.body.number).foregroundStyle(Palette.text).frame(width: 108, alignment: .leading)
            Text(status["successRate"]?.number.map { "\(Int(jsRound($0 * 100)))%" } ?? "—")
                .textStyle(Typography.body.number).foregroundStyle(Palette.text).frame(width: 56, alignment: .leading)
            Text(formatSeconds(status["hedgeThresholdSec"]?.number))
                .textStyle(Typography.body.number).foregroundStyle(Palette.text).frame(width: 60, alignment: .leading)
            Text("\(provider.concurrency)")
                .textStyle(Typography.body.number).foregroundStyle(Palette.text).frame(width: 36, alignment: .leading)
            Toggle("", isOn: Binding(get: { provider.enabled }, set: { value in toggle(provider, value) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 44, alignment: .leading)
            HStack(spacing: Spacing.xs) {
                Button { runProbe(provider, real: false) } label: { Image(systemName: "testtube.2") }.help("测试连通性（免费）")
                Button { realProbe = provider } label: { Image(systemName: "bolt") }.help("真实生成一张测速（会扣一张图的费用）")
                Button { editing = provider } label: { Image(systemName: "pencil") }.help("编辑")
                Button(role: .destructive) { deleting = provider } label: { Image(systemName: "trash") }.help("删除")
            }
            .buttonStyle(.iconAction)
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    func reloadStatuses() async {
        if let result = try? await model.core?.providerStatuses() { statuses = result }
    }

    func reloadAll() async {
        await model.reloadSettings()
        await reloadStatuses()
    }

    func move(_ index: Int, _ delta: Int) {
        var ids = providers.map(\.id)
        let item = ids.remove(at: index)
        ids.insert(item, at: index + delta)
        Task {
            await model.perform { try await model.core?.reorderProviders(ids) }
            await reloadAll()
        }
    }

    func toggle(_ provider: ImageProvider, _ enabled: Bool) {
        var next = provider
        next.enabled = enabled
        Task {
            await model.perform { _ = try await model.core?.saveProvider(next) }
            await reloadAll()
        }
    }

    func runProbe(_ provider: ImageProvider, real: Bool) {
        probe = ProbeState(providerName: provider.name)
        Task {
            do {
                let report = try await model.core?.probeProvider(provider.id, realImage: real)
                probe?.report = report ?? .emptyObject
                await reloadAll()
            } catch {
                probe = nil
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct ProbeSheet: View {
    let state: ProbeState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("测试结果：\(state.providerName)").textStyle(Typography.title).foregroundStyle(Palette.text)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let report = state.report {
                if let error = report["modelsError"]?.string {
                    Banner(.warning, "模型列表读取失败：\(error)", message: "有些中转站不提供模型列表，不影响生图。")
                } else {
                    let count = report["models"].items.count
                    Banner(report["hasModel"] == .bool(false) ? .warning : .success, report["hasModel"] == .bool(false) ? "密钥可用，但模型列表里没有这个模型名，请核对" : "密钥可用\(count > 0 ? "，共 \(count) 个模型" : "")")
                }
                if let switched = report["sizeSwitched"]?.string {
                    Banner(.info, "这条线路不收像素尺寸，已自动改为比例 \(switched)")
                }
                if let image = report["image"].truthyValue {
                    if image["ok"].isTruthy {
                        Banner(.success, "出图成功：\(Int(jsRound((image["durationMs"]?.number ?? 0) / 1000))) 秒，发送尺寸 \(image["requestSize"].text)，返回 \(image["width"]?.int ?? 0)×\(image["height"]?.int ?? 0)")
                        if let dataUrl = image["dataUrl"]?.string, let data = Data(base64Encoded: String(dataUrl.split(separator: ",").last ?? "")), let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 360)
                                .clipShape(Radius.shape(Radius.medium))
                                .overlay(Radius.shape(Radius.medium).strokeBorder(Palette.screenshotEdge, lineWidth: Palette.hairline))
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        Banner(.error, "出图失败：\(image["reason"].text)")
                    }
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("测试中…真实生图通常需要 15–90 秒。").textStyle(Typography.body).foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.dialogNewWidth)
        .background(Palette.card)
    }
}

/// 生图策略：系统设置样式，改了就保存。
struct StrategyGroups: View {
    @Environment(AppModel.self) private var model

    func save(_ patch: JSON) {
        Task {
            await model.perform { _ = try await model.core?.updateSettings(["image": patch]) }
            await model.reloadSettings()
        }
    }

    var body: some View {
        let image = model.settings.image
        let hedge = image.hedge
        AdaptiveColumns(breakpoint: 760, spacing: Spacing.lg) {
            SettingsGroup(title: "生图") {
                SettingsRow(label: "目标尺寸", info: "只收比例的线路会自动换成最接近的比例（864x1824 → 1:2）。") {
                    CommitTextField(placeholder: "864x1824", value: image.targetSize) { save(["targetSize": .string($0)]) }.frame(width: Metrics.formLabelWidth)
                }
                SettingsRow(label: "质量") {
                    Picker("", selection: Binding(get: { image.quality }, set: { save(["quality": .string($0)]) })) {
                        ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: Metrics.formLabelWidth, alignment: .trailing)
                }
                SettingsRow(label: "全局并发上限", info: "所有项目加起来同时生成的图片数。") {
                    ConcurrencyPicker(value: image.globalConcurrency, presets: IMAGE_CONCURRENCY_PRESETS, unit: "张") { save(["globalConcurrency": .number(Double($0))]) }
                }
                SettingsRow(label: "每屏最多尝试") {
                    NumberField(value: image.maxAttemptsPerScreen, range: 1...10, suffix: "次") { save(["maxAttemptsPerScreen": .number(Double($0))]) }
                }
                SettingsRow(label: "检查没通过时最多重新生成") {
                    NumberField(value: image.gateRegenerateLimit, range: 1...6, suffix: "次") { save(["gateRegenerateLimit": .number(Double($0))]) }
                }
                SettingsRow(label: "满载时分流", info: "首选线路并发满了，直接发给同一画风组还有空位的线路，不排队。关闭则严格按顺序排队。") {
                    Toggle("", isOn: Binding(get: { image.spillover }, set: { save(["spillover": .bool($0)]) })).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup(title: "超时补发", footer: "某张图超过补发线还没回来，向另一条线路再发一次，先出图的用。") {
                SettingsRow(label: "开启补发") {
                    Toggle("", isOn: Binding(get: { hedge.enabled }, set: { save(["hedge": ["enabled": .bool($0)]]) })).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(label: "补发线百分位", info: "取这条线路最近 50 次耗时的这个百分位作为补发线，再限制在下面的上下限之间。") {
                    NumberField(value: Int(hedge.percentile), range: 50...99, suffix: "%") { save(["hedge": ["percentile": .number(Double($0))]]) }
                }
                SettingsRow(label: "补发线最少") {
                    NumberField(value: Int(hedge.minSec), range: 5...600, suffix: "秒") { save(["hedge": ["minSec": .number(Double($0))]]) }
                }
                SettingsRow(label: "补发线最多") {
                    NumberField(value: Int(hedge.maxSec), range: 10...900, suffix: "秒") { save(["hedge": ["maxSec": .number(Double($0))]]) }
                }
                SettingsRow(label: "每次运行最多补发", hint: "0 等于关闭") {
                    NumberField(value: hedge.maxPerBatch, range: 0...100, suffix: "张") { save(["hedge": ["maxPerBatch": .number(Double($0))]]) }
                }
                SettingsRow(label: "允许补发到不同模型", info: "关闭时只补发到「画风组」相同的线路，画风和其他屏保持一致。") {
                    Toggle("", isOn: Binding(get: { hedge.allowCrossModel }, set: { save(["hedge": ["allowCrossModel": .bool($0)]]) })).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}
