import StudioCore
import SwiftUI

extension ProjectsView {
    var query: String { model.listQuery }
    var statusFilter: String { model.listStatus }
    var timeFilter: String { model.listTime }
    var batchFilter: String { model.listBatch }
    var pickedDate: Date { model.listPickedDate }
    /// 有筛选条件（状态、时间、批次）在生效
    var filtersActive: Bool { timeFilter != "all" || batchFilter != "all" }

    var rows: [ProjectRow] {
        let filtered = model.projects.filter { project in
            // 按名单处理后：只看名单里的这批，其他筛选暂不生效
            if let only = model.listOnly {
                guard only.contains(project.dir) else { return false }
                return query.isEmpty || project.name.lowercased().contains(query.lowercased())
            }
            if !query.isEmpty {
                // 搜索时在全部项目里找，不受分组、时间、批次筛选限制
                return project.name.lowercased().contains(query.lowercased())
            }
            // 刚看过的项目不被筛掉
            if project.dir == model.stickyProject { return true }
            if !matchesTime(project) { return false }
            if batchFilter != "all", project.batchId != batchFilter { return false }
            return projectGroup(project).rawValue == activeGroup.rawValue
        }
        return sorted(filtered)
    }

    func sorted(_ list: [ProjectRow]) -> [ProjectRow] {
        let ascending = sortAscending
        func order<T: Comparable>(_ a: T, _ b: T, _ tieA: ProjectRow, _ tieB: ProjectRow) -> Bool {
            if a == b { return tieA.recency > tieB.recency }
            return ascending ? a < b : a > b
        }
        switch sortKey {
        case "name": return list.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            if result == .orderedSame { return $0.recency > $1.recency }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        case "status": return list.sorted { order($0.statusSortKey, $1.statusSortKey, $0, $1) }
        case "build": return list.sorted { order($0.lastBuildSortKey, $1.lastBuildSortKey, $0, $1) }
        default: return list.sorted { order($0.recency, $1.recency, $0, $1) }
        }
    }

    /// 表格表头的排序状态和 sortKey 互相换算
    var sortOrder: Binding<[KeyPathComparator<ProjectRow>]> {
        Binding(get: {
            let direction: SortOrder = sortAscending ? .forward : .reverse
            switch sortKey {
            case "name": return [KeyPathComparator(\ProjectRow.name, order: direction)]
            case "status": return [KeyPathComparator(\ProjectRow.statusSortKey, order: direction)]
            case "build": return [KeyPathComparator(\ProjectRow.lastBuildSortKey, order: direction)]
            default: return [KeyPathComparator(\ProjectRow.recency, order: direction)]
            }
        }, set: { next in
            guard let first = next.first else { return }
            switch first.keyPath {
            case \ProjectRow.name: sortKey = "name"
            case \ProjectRow.statusSortKey: sortKey = "status"
            case \ProjectRow.lastBuildSortKey: sortKey = "build"
            default: sortKey = "recent"
            }
            sortAscending = first.order == .forward
        })
    }

    /// 所有批次，最新的在前
    var batches: [(id: String, label: String, count: Int)] {
        var seen: [String: (label: String, count: Int, at: Double)] = [:]
        for project in model.projects {
            guard let id = project.batchId, seen[id] == nil else { continue }
            seen[id] = (project.batchLabel, project.batchCount, project.json["batch"]?["at"]?.number ?? 0)
        }
        return seen.sorted { $0.value.at > $1.value.at }.map { (id: $0.key, label: $0.value.label, count: $0.value.count) }
    }

    var rangeLabel: String {
        if batchFilter != "all", let batch = batches.first(where: { $0.id == batchFilter }) { return "\(batch.label)（\(batch.count)）" }
        if timeFilter == "date" { return pickedDate.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN"))) }
        return TIME_FILTERS.first { $0.value == timeFilter }?.label ?? "全部时间"
    }

    func matchesTime(_ project: ProjectRow) -> Bool {
        guard timeFilter != "all" else { return true }
        let times = project.activityDates
        let calendar = Calendar.current
        switch timeFilter {
        case "today": return times.contains { calendar.isDateInToday($0) }
        case "yesterday": return times.contains { calendar.isDateInYesterday($0) }
        case "week":
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
            return times.contains { $0 >= start }
        case "date": return times.contains { calendar.isDate($0, inSameDayAs: pickedDate) }
        default: return true
        }
    }

    var selectedRows: [ProjectRow] { model.projects.filter { selection.contains($0.dir) } }

}
