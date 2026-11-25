import SwiftUI
import XCTest
@testable import Planner

final class ContactSetMapTests: XCTestCase {
    func testScopedCountsAndRoutesRemainExact() {
        let a = UUID(), b = UUID(), c = UUID(), hidden = UUID()
        let onlyA = UUID(), both = UUID(), triple = UUID(), outside = UUID(), filteredOut = UUID()
        let universe = Set([onlyA, both, triple, outside])
        let tags = [a, b, c]
        let members: [UUID: Set<UUID>] = [
            a: [onlyA, both, triple, filteredOut],
            b: [both, triple], c: [triple], hidden: [outside]
        ]
        let map = ContactSetMap(universe: universe, tags: tags, memberships: members)
        XCTAssertEqual(map.insideCount, 3)
        XCTAssertEqual(map.outsideCount, 1)
        XCTAssertEqual(map.components.count, 1)
        for component in map.components {
            for region in component.regions {
                XCTAssertEqual(ContactSetMap.people(for: .exact(region.tags), in: universe, tags: tags,
                                                   memberships: members).count, region.count)
            }
        }
        XCTAssertEqual(ContactSetMap.people(for: .exact([a, b]), in: universe, tags: tags, memberships: members), [both])
        XCTAssertEqual(ContactSetMap.people(for: .outside, in: universe, tags: tags, memberships: members), [outside])
        XCTAssertEqual(ContactSetMap.people(for: .union, in: universe, tags: tags, memberships: members), [onlyA, both, triple])
    }

    func testLiveScopeIncludesAnEmptyCircleWhenSomeoneJoinsIt() {
        let family = ContactTag(categoryID: "family", name: "陸家")
        let otherFamily = ContactTag(categoryID: "family", name: "賴家")
        let employer = ContactTag(categoryID: "work", name: "UMC")
        var catalog = ContactTagCatalog()
        catalog.tags = [family, otherFamily, employer]
        let amy = UUID(), ben = UUID(), claire = UUID()
        let universe: Set<UUID> = [amy, ben, claire]
        let scope = ContactMapCircles.category("family")
        let tags = scope.tagIDs(in: catalog, contacts: [:])
        var memberships: [UUID: Set<UUID>] = [family.id: [amy], employer.id: [claire]]
        let before = ContactSetMap(universe: universe, tags: tags, memberships: memberships)
        XCTAssertEqual(before.components.count, 1)
        XCTAssertEqual(ContactSetMap.people(for: .outside, in: universe, tags: tags, memberships: memberships), [ben, claire])

        memberships[otherFamily.id] = [amy, ben]
        let currentTags = scope.tagIDs(in: catalog, contacts: [:])
        let after = ContactSetMap(universe: universe, tags: currentTags, memberships: memberships)
        XCTAssertEqual(after.outsideCount, 1)
        XCTAssertEqual(ContactSetMap.people(for: .outside, in: universe, tags: currentTags, memberships: memberships), [claire])
        XCTAssertEqual(ContactSetMap.people(for: .exact([family.id]), in: universe, tags: currentTags, memberships: memberships), [])
    }

    func testLayoutAvoidsPhantomIntersections() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let first = UUID(), second = UUID(), middle = UUID(), left = UUID(), right = UUID()
        let people: Set<UUID> = [first, second, middle, left, right]
        let tags = [a, b, c]
        let map = ContactSetMap(universe: people, tags: tags, memberships: [
            a: [first, left], b: [second, right], c: [middle, left, right]
        ])
        try assertLayoutMatches(XCTUnwrap(map.components.first))
    }

    func testPairwiseOverlapsWithNoTripleLeaveCenterClear() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let equalPairs: [[UUID]] = [[a, b], [b, c], [a, c]]
        for singles in [[[a], [b], [c]], [[a], [b]], [[c]], []] {
            let component = ContactSetMap.Component(tags: [a, b, c], regions: (equalPairs + singles).map {
                ContactSetMap.Region(tags: $0, count: 1)
            })
            try assertLayoutMatches(component)
            let layout = try XCTUnwrap(ContactSetLayout(component))
            for outline in layout.outlines {
                XCTAssertFalse(outline.path(in: CGSize(width: 1, height: 1)).contains(CGPoint(x: 0.5, y: 0.5)))
            }
        }
    }

    func testUnsupportedComplexShapeKeepsAllRegionsForMatrix() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let tags = [a, b, c, d]
        let shared = UUID()
        let privateMembers = tags.map { _ in UUID() }
        let memberships = Dictionary(uniqueKeysWithValues: zip(tags, privateMembers).map { tag, person in
            (tag, Set([person, shared]))
        })
        let universe = Set(privateMembers + [shared])
        let map = ContactSetMap(universe: universe, tags: tags, memberships: memberships)
        let component = try XCTUnwrap(map.components.first)
        XCTAssertNil(ContactSetLayout(component))
        XCTAssertEqual(component.regions.count, 5)
        XCTAssertEqual(ContactSetMap.people(for: .exact(tags), in: universe, tags: tags, memberships: memberships), [shared])
    }

    private func assertLayoutMatches(_ component: ContactSetMap.Component,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(ContactSetLayout(component), file: file, line: line)
        let size = CGSize(width: 1, height: 1)
        let contours = layout.outlines.map { ($0.tags, $0.path(in: size)) }
        func membership(at point: CGPoint) -> Set<UUID> {
            Set(contours.filter { $0.1.contains(point) }.flatMap { $0.0 })
        }
        let expected = Set(component.regions.map { Set($0.tags) })
        for region in component.regions {
            let point = try XCTUnwrap(layout.points[region.tags])
            XCTAssertEqual(membership(at: point), Set(region.tags), file: file, line: line)
        }
        for x in 1..<40 {
            for y in 1..<40 {
                let mask = membership(at: CGPoint(x: (Double(x) + 0.17) / 40, y: (Double(y) + 0.41) / 40))
                XCTAssertTrue(mask.isEmpty || expected.contains(mask), file: file, line: line)
            }
        }
    }
}
