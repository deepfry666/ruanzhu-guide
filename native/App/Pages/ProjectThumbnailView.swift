import StudioCore
import SwiftUI

struct ProjectThumbnailView: View {
    let thumbnail: ProjectThumbnail?
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        ScreenImage(path: thumbnail?.path, version: thumbnail?.modifiedAt, maxPixel: max(1, Int((height * displayScale).rounded(.up))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(Radius.shape(Radius.small))
            .accessibilityLabel(thumbnail == nil ? "暂无截图" : "第一张截图")
    }
}
