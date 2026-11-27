import StudioCore
import SwiftUI

/// 与自动更新资格使用同一组步骤；本视图只展示，不触发运行。
struct BundleStatusCard: View {
    let data: ProjectData

    private var pending: [PipelineStepName] {
        STEP_ORDER.filter {
            let status = data.stepStatus($0)
            return status != .done && status != .skipped
        }
    }

    var body: some View {
        Card(title: "交付包状态") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if data.bundleUpdating {
                    TagView(text: "更新中", tone: .blue)
                    Text("正在更新交付文件，打开或导出时会等待完成。")
                } else if let error = data.bundleUpdateError {
                    TagView(text: "待更新", tone: .red)
                    Text(error)
                } else if !pending.isEmpty || data.bundleFiles.isEmpty {
                    TagView(text: "待更新", tone: .orange)
                    Text(data.bundleFiles.isEmpty ? "还没有交付文件。" : "尚未完成：\(pending.map { UI_STEP_LABELS[$0] ?? $0.rawValue }.joined(separator: "、"))")
                    if pending.contains(where: { $0 != .receipt && $0 != .build }) {
                        Text(data.readOnly ? "项目只读，需要取消已提交后才能继续。" : "需要继续生成（可能调用 AI），请使用工具栏「继续」。")
                    } else if !data.readOnly {
                        Text("等待本机自动更新。")
                    }
                } else {
                    TagView(text: "最新", tone: .green)
                    Text("交付文件已是最新。")
                }
            }
            .textStyle(Typography.body)
            .foregroundStyle(Palette.textSecondary)
        }
    }
}
