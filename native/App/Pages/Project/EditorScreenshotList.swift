import StudioCore
import SwiftUI

extension EditorTab {
    var screenshotList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if data.content != nil {
                Button("封面介绍") { selectedScreen = "overview" }
            }
            if !sections.isEmpty { Button("设计说明") { selectedScreen = "design" } }
            ForEach(Array(data.screens.enumerated()), id: \.element.id) { index, screen in
                let tag = gateTag(screen.gate)
                Button { selectedScreen = screen.id } label: {
                    HStack(spacing: Spacing.md) {
                        ScreenImage(path: screen.file, version: screen.mtime, maxPixel: 160)
                            .frame(width: Metrics.thumbnailEditorList, height: Metrics.listRowHeight)
                            .clipShape(Radius.shape(Radius.small))
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("图\(index + 1) · \(screen.title)").textStyle(Typography.bodyStrong)
                            TagView(text: tag.0, tone: tag.1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.sm)
                    .background(selectedScreen == screen.id || (selectedScreen.isEmpty && index == 0) ? Palette.primary.tint : Palette.card, in: Radius.shape(Radius.medium))
                    .contentShape(Rectangle())
                }.buttonStyle(.pressPlain)
            }
        }
        .focusable()
        .onKeyPress(.upArrow) { selectNeighbor(-1); return .handled }
        .onKeyPress(.downArrow) { selectNeighbor(1); return .handled }
    }

    func selectNeighbor(_ offset: Int) {
        guard !data.screens.isEmpty else { return }
        let current = data.screens.firstIndex { $0.id == selectedScreen } ?? 0
        let next = min(data.screens.count - 1, max(0, current + offset))
        selectedScreen = data.screens[next].id
    }

    var statusLine: some View {
        HStack(spacing: Spacing.sm) {
            if data.submitted {
                Text("已提交，只能查看；要修改请先取消已提交").foregroundStyle(Palette.textSecondary)
            } else if data.readOnly {
                Text("只读项目，不能修改").foregroundStyle(Palette.textSecondary)
            } else if running {
                Label("正在运行，跑完后才能修改", systemImage: "hourglass").foregroundStyle(Palette.textSecondary)
            } else {
                switch saveState {
                case .saving: ProgressView().controlSize(.small); Text("正在保存…").foregroundStyle(Palette.textSecondary)
                case .saved(let date): Label("已自动保存 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").foregroundStyle(Palette.textSecondary)
                case .failed(let message): Label("没有保存：\(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                case .idle: Label("文字改了自动保存", systemImage: "checkmark.circle").foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Text("保存后交付包约 3 秒自动更新；需要 AI 时请点「继续」").textStyle(Typography.body).foregroundStyle(Palette.textSecondary)
            }
        }
    }

}
