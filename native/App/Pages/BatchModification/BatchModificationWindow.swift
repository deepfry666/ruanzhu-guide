import StudioCore
import SwiftUI

struct BatchModificationPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        @Bindable var model = model
        content.sheet(item: $model.batchModification) { request in
            BatchModificationWindow(state: BatchModificationState(model: model, dirs: request.dirs), finished: request.finished)
                .environment(model).designSystem()
                .overlay(alignment: .bottom) { ToastOverlay(toasts: model.toasts) }
        }
    }
}

struct BatchModificationWindow: View {
    @State var state: BatchModificationState
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var discardDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("批量修改").textStyle(Typography.title)
            Text(state.step == .write ? "1 写意见   →   2 预览   →   3 确认执行" : state.step == .preview ? "1 写意见   →   2 预览（当前）   →   3 确认执行" : "1 写意见   →   2 预览   →   3 确认执行（当前）")
                .textStyle(Typography.caption).foregroundStyle(Palette.textSecondary)
            ScrollView {
                switch state.step {
                case .write: BatchModificationWrite(state: state)
                case .preview: BatchModificationPreview(state: state)
                case .confirm: BatchModificationConfirmation(state: state)
                }
            }
            .disabled(state.busy)
            .overlay {
                if state.busy {
                    ProgressView(state.progress.isEmpty ? "正在保存…" : state.progress)
                        .padding(Spacing.xl).surface()
                }
            }
            Divider()
            HStack(spacing: Spacing.sm) {
                if state.step != .write {
                    Button("上一步") { state.step = state.step == .confirm ? .preview : .write }.disabled(state.busy)
                }
                Spacer()
                Button("取消") {
                    if !state.hasDraft { dismiss() } else { discardDraft = true }
                }.keyboardShortcut(.cancelAction).disabled(state.busy)
                switch state.step {
                case .write:
                    Button("下一步：预览") { state.next() }.buttonStyle(.primary).disabled(!state.canNext)
                case .preview:
                    Button("下一步：确认执行") { state.step = .confirm }.buttonStyle(.primary).disabled(state.busy || !state.hasWork)
                case .confirm:
                    MorphButton(title: "确认执行", doneTitle: "已提交") {
                        let ok = await state.execute()
                        if ok { finished(); dismiss() }
                        return ok
                    }
                    .disabled(state.busy || !state.hasWork)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: Metrics.dialogBatchWidth, height: Metrics.dialogNewWidth)
        .interactiveDismissDisabled(state.busy || state.hasDraft)
        .task {
            state.busy = true
            await state.refresh()
            if let names = state.model.devNameListText {
                await state.addNames(names)
                state.model.devNameListText = nil
            }
            state.busy = false
        }
        .alert("整理意见会调用收费模型", isPresented: $state.analysisConsent) {
            Button("取消", role: .cancel) {}
            Button("同意费用，整理意见") { Task { await state.analyze() } }
        } message: {
            Text("将为 \(state.requestedAnalysis.count) 个项目分别调用一次文字模型，把待处理意见整理为动作。此步不生成图片；预览后仍需确认才执行修改。已保存的意见会保留，取消预览不会删除。")
        }
        .alert("批量修改未全部完成", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("好") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .alert("放弃尚未保存的意见？", isPresented: $discardDraft) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃并关闭", role: .destructive) { dismiss() }
        } message: { Text("已保存到项目的意见会保留。") }
    }
}

struct PendingModificationSummary: View {
    let data: ProjectData
    @Environment(AppModel.self) private var model
    var pending: [FeedbackItem] { (ProjectState(data.state).feedback ?? []).filter { $0.status == "pending" } }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("待处理意见（\(pending.count)）").textStyle(Typography.bodyStrong)
                Spacer()
                if !data.readOnly {
                    Button("批量修改…") { model.batchModification = BatchModificationRequest(dirs: [data.dir]) }
                        .disabled(data.runningFlag || data.status == "running")
                }
            }
            ForEach(Array(pending.enumerated()), id: \.offset) { index, item in
                Text("\(index + 1). \(item.text ?? "")").textStyle(Typography.body).textSelection(.enabled)
            }
            if pending.isEmpty { Text("没有待处理意见").textStyle(Typography.caption).foregroundStyle(Palette.textSecondary) }
        }.padding(Spacing.lg).surface()
    }
}
