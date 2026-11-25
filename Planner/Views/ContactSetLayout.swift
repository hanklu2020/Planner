import SwiftUI

struct ContactSetLayout {
    struct Outline {
        enum Shape {
            case ellipse(CGRect)
            case ringSlice(start: Int, length: Int)
        }

        let tags: [UUID]
        let shape: Shape

        init(tags: [UUID], rect: CGRect) {
            self.tags = tags
            shape = .ellipse(rect)
        }

        init(tag: UUID, start: Int, length: Int) {
            tags = [tag]
            shape = .ringSlice(start: start, length: length)
        }

        func path(in size: CGSize) -> Path {
            switch shape {
            case .ellipse(let rect):
                return Path(ellipseIn: CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                              width: rect.width * size.width, height: rect.height * size.height))
            case .ringSlice(let start, let length):
                return Path { path in
                    let end = start + length
                    func point(_ sample: Int, radius: CGFloat) -> CGPoint {
                        let normalized = ContactSetLayout.ringPoint(sample: sample, radius: radius)
                        return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
                    }
                    path.move(to: point(start, radius: 0.46))
                    for sample in (start + 1)...end {
                        path.addLine(to: point(sample, radius: 0.46))
                    }
                    for sample in (start...end).reversed() {
                        path.addLine(to: point(sample, radius: 0.19))
                    }
                    path.closeSubpath()
                }
            }
        }
    }

    private static let ringSamples = 120
    let outlines: [Outline]
    let points: [[UUID]: CGPoint]

    init?(_ component: ContactSetMap.Component) {
        let tags = component.tags
        let patterns = Set(component.regions.map { Set($0.tags) })
        let singles = tags.filter { patterns.contains([$0]) }
        let pairs = patterns.filter { $0.count == 2 }

        switch tags.count {
        case _ where component.regions.count == 1:
            outlines = [Outline(tags: tags, rect: CGRect(x: 0.08, y: 0.12, width: 0.84, height: 0.76))]
            points = [component.regions[0].tags: CGPoint(x: 0.5, y: 0.5)]
        case 2:
            if singles.count == 1, let outer = singles.first, let inner = tags.first(where: { $0 != outer }) {
                outlines = [
                    Outline(tags: [outer], rect: CGRect(x: 0.05, y: 0.08, width: 0.90, height: 0.84)),
                    Outline(tags: [inner], rect: CGRect(x: 0.37, y: 0.27, width: 0.43, height: 0.47))
                ]
                points = [[outer]: CGPoint(x: 0.23, y: 0.50), tags: CGPoint(x: 0.58, y: 0.50)]
            } else {
                outlines = [
                    Outline(tags: [tags[0]], rect: CGRect(x: 0.04, y: 0.10, width: 0.63, height: 0.80)),
                    Outline(tags: [tags[1]], rect: CGRect(x: 0.33, y: 0.10, width: 0.63, height: 0.80))
                ]
                points = [[tags[0]]: CGPoint(x: 0.22, y: 0.50), [tags[1]]: CGPoint(x: 0.78, y: 0.50), tags: CGPoint(x: 0.5, y: 0.50)]
            }
        case 3 where patterns.count == 7:
            let a = tags[0], b = tags[1], c = tags[2]
            outlines = [
                Outline(tags: [a], rect: CGRect(x: 0.08, y: 0.10, width: 0.54, height: 0.56)),
                Outline(tags: [b], rect: CGRect(x: 0.38, y: 0.10, width: 0.54, height: 0.56)),
                Outline(tags: [c], rect: CGRect(x: 0.23, y: 0.38, width: 0.54, height: 0.56))
            ]
            points = [
                [a]: CGPoint(x: 0.23, y: 0.31), [b]: CGPoint(x: 0.77, y: 0.31), [c]: CGPoint(x: 0.50, y: 0.80),
                [a, b]: CGPoint(x: 0.50, y: 0.25), [a, c]: CGPoint(x: 0.31, y: 0.55), [b, c]: CGPoint(x: 0.69, y: 0.55),
                tags: CGPoint(x: 0.50, y: 0.51)
            ]
        case 3 where pairs.count == 3 && patterns.count == singles.count + pairs.count:
            // The cyclic order keeps each tag connected. Drop empty sectors so actual
            // regions and their buttons have room, while the center remains an empty triple.
            let a = tags[0], b = tags[1], c = tags[2]
            let sectors = [[a], [a, b], [b], [b, c], [c], [a, c]].filter { patterns.contains(Set($0)) }
            let step = Self.ringSamples / sectors.count
            var arcs: [Outline] = []
            for tag in tags {
                let length = sectors.filter { $0.contains(tag) }.count * step
                guard let first = sectors.indices.first(where: { index in
                    let previous = (index + sectors.count - 1) % sectors.count
                    return sectors[index].contains(tag) && !sectors[previous].contains(tag)
                }) else { return nil }
                arcs.append(Outline(tag: tag, start: first * step, length: length))
            }
            outlines = arcs
            points = Dictionary(uniqueKeysWithValues: sectors.enumerated().map { sector, ids in
                (ids, Self.ringPoint(sample: sector * step + step / 2, radius: 0.325))
            })
        case 3 where singles.count == 3 && pairs.count == 2 && patterns.count == 5:
            guard let hub = pairs.reduce(Set(tags), { $0.intersection($1) }).first else { return nil }
            let leaves = tags.filter { $0 != hub }, left = leaves[0], right = leaves[1]
            outlines = [
                Outline(tags: [hub], rect: CGRect(x: 0.035, y: 0.37, width: 0.93, height: 0.46)),
                Outline(tags: [left], rect: CGRect(x: 0.04, y: 0.11, width: 0.42, height: 0.55)),
                Outline(tags: [right], rect: CGRect(x: 0.54, y: 0.11, width: 0.42, height: 0.55))
            ]
            points = Dictionary(uniqueKeysWithValues: component.regions.map { region in
                let x = region.tags.contains(left) ? 0.25 : region.tags.contains(right) ? 0.75 : 0.50
                let y = region.tags.count == 2 ? 0.51 : region.tags.contains(hub) ? 0.63 : 0.26
                return (region.tags, CGPoint(x: x, y: y))
            })
        default:
            return nil
        }
    }

    private static func ringPoint(sample: Int, radius: CGFloat) -> CGPoint {
        let total = ringSamples
        let angle = Double(sample % total) * 2 * .pi / Double(total) - 2 * .pi / 3
        return CGPoint(x: 0.5 + radius * CGFloat(cos(angle)), y: 0.5 + radius * CGFloat(sin(angle)))
    }
}
