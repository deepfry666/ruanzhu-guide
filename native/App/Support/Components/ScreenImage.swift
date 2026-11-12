import ImageIO
import StudioCore
import SwiftUI

/// 截图缩略图。按显示需要的大小在后台解码一次，存进内存缓存（按文件和修改时间区分），
/// 界面线程不再读硬盘、不再全尺寸解码 PNG（以前每次重画都要做，编辑页一次 0.15 秒）。
/// 加载中显示「骨架闪光」，加载完成后截图 0.2 秒淡入；没有路径或读不出来时是静止的填充色占位。
struct ScreenImage: View {
    let path: String?
    var version: Double? = nil
    /// 解码到的最长边像素：编辑页 440 点高，2 倍屏够用；大图预览传更大的值
    var maxPixel: Int = 1000
    @State private var loaded: NSImage?
    @State private var failedKey: String?

    private var key: String? {
        guard let path else { return nil }
        return "\(path)#\(version ?? FS.mtimeMs(path) ?? 0)#\(maxPixel)"
    }

    var body: some View {
        let image = key.flatMap(ScreenImageCache.shared.image) ?? loaded
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else if key == nil || key == failedKey {
                Rectangle().fill(Palette.fill)
            } else {
                Skeleton(cornerRadius: nil)
            }
        }
        .animation(Motion.fade, value: image != nil)
        .task(id: key) {
            guard let key, let path, ScreenImageCache.shared.image(key) == nil else { return }
            loaded = await ScreenImageCache.shared.load(path: path, key: key, maxPixel: maxPixel)
            if loaded == nil { failedKey = key }
        }
    }
}

@MainActor
final class ScreenImageCache {
    static let shared = ScreenImageCache()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    func image(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func load(path: String, key: String, maxPixel: Int) async -> NSImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(DecodedImage.init)
        }.value
        guard let cgImage = decoded?.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// 后台解码好的图交回界面线程（解码完就不再改动）
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}
