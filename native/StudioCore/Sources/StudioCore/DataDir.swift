import Foundation

/// 软件数据目录：设置、加密的密钥、调用记录和项目状态。
public func nativeDataDir() -> String {
    Path.join(NSHomeDirectory(), "Library", "Application Support", "软件指南生成器（原生版）")
}
