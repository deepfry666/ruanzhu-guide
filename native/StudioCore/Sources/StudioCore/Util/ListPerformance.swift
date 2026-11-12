import Foundation

/// 仅试用或开发控制时输出，不记录路径和状态内容。
public enum ListPerformance {
    public static let enabled = ProcessInfo.processInfo.environment["MS_TRIAL"] == "1"
        || ProcessInfo.processInfo.environment["MS_DEV_CONTROL"] != nil
    public static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    private static let totals = Locked<(read: Double, parse: Double, summary: Double)>((0, 0, 0))

    static func add(read: Double, parse: Double) {
        guard enabled else { return }
        totals.withLock { $0.read += read; $0.parse += parse }
    }

    static func addSummary(_ elapsed: Double) {
        guard enabled else { return }
        totals.withLock { $0.summary += elapsed }
    }

    static func begin() {
        guard enabled else { return }
        totals.withLock { $0 = (0, 0, 0) }
    }

    static func finish(since start: Double) {
        guard enabled else { return }
        let elapsed = now - start
        let values = totals.withLock { value in
            let result = value
            value = (0, 0, 0)
            return result
        }
        report("read", milliseconds: values.read)
        report("parse", milliseconds: values.parse)
        report("summary", milliseconds: values.summary)
        report("indexAndSettings", milliseconds: max(0, elapsed - values.read - values.parse - values.summary))
        report("list", milliseconds: elapsed)
    }

    public static func report(_ phase: String, milliseconds: Double) {
        guard enabled else { return }
        let line = String(format: "list-performance %@ %.3f ms\n", phase, milliseconds)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
