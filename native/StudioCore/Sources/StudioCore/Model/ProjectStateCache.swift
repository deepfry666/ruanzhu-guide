import Foundation

/// 状态文件的进程内快照；锁覆盖读取和写入，避免旧读取覆盖刚写入的缓存。
final class ProjectStateCache: Sendable {
    private struct Stamp: Equatable {
        let modified: Date
        let size: UInt64
        let identity: UInt64

        init?(_ file: String) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? NSNumber,
                  let identity = attrs[.systemFileNumber] as? NSNumber else { return nil }
            self.modified = modified
            self.size = size.uint64Value
            self.identity = identity.uint64Value
        }
    }
    private struct Entry {
        let stamp: Stamp
        let state: ProjectState
    }
    private let entries = Locked<[String: Entry]>([:])

    func read(_ file: String) throws -> ProjectState? {
        try entries.withLock { cache in
            let started = ListPerformance.now
            let before = Stamp(file)
            if let before, let entry = cache[file], before == entry.stamp {
                ListPerformance.add(read: ListPerformance.now - started, parse: 0)
                return entry.state
            }
            cache[file] = nil
            guard let text = try? FS.readText(file) else { return nil }
            let loaded = ListPerformance.now
            let state: ProjectState
            do { state = ProjectState(try JSON.parse(text)) }
            catch { throw StudioError("JSON 文件损坏：\(file)（\(messageOf(error))）") }
            ListPerformance.add(read: loaded - started, parse: ListPerformance.now - loaded)
            // 外部写入发生在读取过程中时，不把这个快照当作最新版本缓存。
            if let before, Stamp(file) == before { cache[file] = Entry(stamp: before, state: state) }
            return state
        }
    }

    func write(_ file: String, _ state: ProjectState) throws {
        try entries.withLock { cache in
            cache[file] = nil
            let text = state.raw.serialized(pretty: true) + "\n"
            try FS.writeAtomic(file, text)
            // 外部进程可能刚好替换文件；只缓存仍属于本次写入的快照。
            if let stamp = Stamp(file), FS.readTextIfExists(file) == text, Stamp(file) == stamp {
                cache[file] = Entry(stamp: stamp, state: state)
            }
        }
    }

    func remove(_ file: String) {
        entries.withLock { cache in
            cache[file] = nil
            FS.remove(file)
        }
    }
}
