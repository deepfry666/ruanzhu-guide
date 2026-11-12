import SwiftUI

extension ProjectsView {
    var activeGroup: ProjectGroup {
        if let saved = ProjectGroup(rawValue: model.listStatus) { return saved }
        let groups = Set(model.projects.map(projectGroup))
        if groups.contains(.attention) { return .attention }
        if groups.contains(.inProgress) { return .inProgress }
        return .completed
    }

    var groupBar: some View {
        let counts = Dictionary(grouping: model.projects, by: projectGroup).mapValues(\.count)
        return HStack {
            SegmentedTabs(selection: Binding(get: { activeGroup }, set: {
                model.listStatus = $0.rawValue
            }), items: ProjectGroup.allCases.map {
                .init(value: $0, title: $0.title, count: counts[$0] ?? 0)
            })
            Spacer()
        }
    }

    func entranceMode(_ row: ProjectRow) -> EntranceMode {
        !entranceInitialized || initialEntranceIDs.contains(row.dir) ? .stagger : .fade
    }
}
