import Foundation

enum ContactMapSelection: Hashable {
    case union, outside, exact([UUID])
}

enum ContactMapCircles: Hashable {
    case category(String?)
    case person(UUID)

    func tagIDs(in catalog: ContactTagCatalog, contacts: [UUID: Contact]) -> [UUID] {
        switch self {
        case .category(let category):
            return catalog.tags.filter { category == nil || $0.categoryID == category }.map(\.id)
        case .person(let id):
            let personalTags = Set(contacts[id]?.tagIDs ?? [])
            return catalog.tags.filter { personalTags.contains($0.id) }.map(\.id)
        }
    }
}

struct ContactSetMap {
    struct Region: Identifiable, Equatable {
        let tags: [UUID]
        let count: Int
        var id: [UUID] { tags }
    }

    struct Component: Identifiable, Equatable {
        let tags: [UUID]
        let regions: [Region]
        var id: [UUID] { tags }
    }

    let components: [Component]
    let insideCount: Int
    let outsideCount: Int

    init(universe: Set<UUID>, tags: [UUID], memberships: [UUID: Set<UUID>]) {
        var tagsByPerson: [UUID: [UUID]] = [:]
        var visible: [UUID] = []
        for tag in tags {
            let members = (memberships[tag] ?? []).intersection(universe)
            guard !members.isEmpty else { continue }
            visible.append(tag)
            for person in members { tagsByPerson[person, default: []].append(tag) }
        }
        insideCount = tagsByPerson.count
        outsideCount = universe.count - insideCount

        var counts: [[UUID]: Int] = [:]
        var neighbors: [UUID: Set<UUID>] = [:]
        for keys in tagsByPerson.values { counts[keys, default: 0] += 1 }
        for keys in counts.keys {
            guard let first = keys.first else { continue }
            for tag in keys.dropFirst() {
                neighbors[first, default: []].insert(tag)
                neighbors[tag, default: []].insert(first)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element, $0.offset) })
        let regions = counts.map { Region(tags: $0.key, count: $0.value) }.sorted {
            if $0.tags.count != $1.tags.count { return $0.tags.count < $1.tags.count }
            return $0.tags.lexicographicallyPrecedes($1.tags) { order[$0, default: 0] < order[$1, default: 0] }
        }
        let byFirst = Dictionary(grouping: regions) { $0.tags.first }
        var remaining = Set(visible)
        var components: [Component] = []
        for tag in visible where remaining.remove(tag) != nil {
            var nodes = [tag]
            var cursor = 0
            while cursor < nodes.count {
                for next in neighbors[nodes[cursor]] ?? [] where remaining.remove(next) != nil { nodes.append(next) }
                cursor += 1
            }
            nodes.sort { order[$0, default: 0] < order[$1, default: 0] }
            components.append(Component(tags: nodes, regions: nodes.flatMap { byFirst[$0] ?? [] }))
        }
        self.components = components
    }

    static func people(for selection: ContactMapSelection, in universe: Set<UUID>, tags: [UUID],
                       memberships: [UUID: Set<UUID>]) -> Set<UUID> {
        switch selection {
        case .union:
            return tags.reduce(into: Set<UUID>()) { $0.formUnion((memberships[$1] ?? []).intersection(universe)) }
        case .outside:
            return tags.reduce(into: universe) { $0.subtract(memberships[$1] ?? []) }
        case .exact(let included):
            let required = Set(included)
            guard required.isSubset(of: Set(tags)) else { return [] }
            return tags.reduce(into: universe) { result, tag in
                if required.contains(tag) { result.formIntersection(memberships[tag] ?? []) }
                else { result.subtract(memberships[tag] ?? []) }
            }
        }
    }
}
