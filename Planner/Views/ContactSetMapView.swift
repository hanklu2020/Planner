import SwiftUI

struct ContactSetMapView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let map: ContactSetMap
    let catalog: ContactTagCatalog
    let openTag: (UUID) -> Void
    let openResult: (ContactMapSelection) -> Void

    var body: some View {
        let tags = Dictionary(uniqueKeysWithValues: catalog.tags.map { ($0.id, $0) })
        let names = tags.mapValues { catalog.name(for: $0) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                summary("聯集", count: map.insideCount, selection: .union)
                summary("圈外", count: map.outsideCount, selection: .outside)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if map.components.isEmpty {
                ContentUnavailableView("目前範圍沒有圈子", systemImage: "circle.hexagongrid",
                                       description: Text("可從標籤頁管理圈子，或查看上方的圈外名單。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(map.components) { component in
                            componentView(component, tags: tags, names: names)
                        }
                    }.padding(16)
                }
            }
        }
    }

    private func summary(_ title: String, count: Int, selection: ContactMapSelection) -> some View {
        Button { openResult(selection) } label: {
            Text("\(title) · \(count) 人").font(.subheadline.weight(.semibold))
                .monospacedDigit().frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.plannerAccent)
    }

    @ViewBuilder private func componentView(_ component: ContactSetMap.Component,
                                            tags: [UUID: ContactTag], names: [UUID: String]) -> some View {
        let labels = component.tags.compactMap { tags[$0] }
        let colors = Dictionary(uniqueKeysWithValues: labels.map {
            ($0.id, TagPalette.color(catalog.category(for: $0)?.color ?? ""))
        })
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                legend(labels)
                Text("交集明細").font(.subheadline.weight(.semibold))
                ForEach(component.regions) { region in
                    Button { openResult(.exact(region.tags)) } label: {
                        LabeledContent("只在 " + tagNames(region.tags, in: names), value: "\(region.count) 人")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else if let layout = ContactSetLayout(component) {
                legend(labels)
                DiagramViewport(layout: layout, regions: component.regions, colors: colors, names: names,
                                openTag: openTag, openResult: openResult)
            } else {
                Text("交集明細").font(.subheadline.weight(.semibold))
                ContactSetMatrix(component: component, colors: colors, names: names, openTag: openTag, openResult: openResult)
            }
        }
    }

    private func legend(_ tags: [ContactTag]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    Button { openTag(tag.id) } label: { ContactTagLabel(tag: tag) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityHint("查看這個標籤的所有成員")
                }
            }.padding(.vertical, 3)
        }.scrollIndicators(.hidden)
    }
}

private struct ContactSetMatrix: View {
    let component: ContactSetMap.Component
    let colors: [UUID: Color]
    let names: [UUID: String]
    let openTag: (UUID) -> Void
    let openResult: (ContactMapSelection) -> Void
    @ScaledMetric(relativeTo: .caption) private var columnWidth: CGFloat = 78
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 52

    var body: some View {
        let rows = component.regions
        let membersByRow = rows.map { Set($0.tags) }
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text("人數").font(.caption.weight(.semibold))
                    .frame(width: 58, height: headerHeight)
                ForEach(rows) { row in
                    Button { openResult(.exact(row.tags)) } label: {
                        Text("\(row.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(width: 58, height: rowHeight)
                            .minimumScaleFactor(0.65).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Color.plannerAccent)
                        .accessibilityLabel("只在 \(tagNames(row.tags, in: names))，\(row.count) 人")
                }
            }
            Divider()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(component.tags, id: \.self) { tag in
                        VStack(spacing: 0) {
                            tagHeader(tag)
                            ForEach(rows.indices, id: \.self) { index in
                                Circle()
                                    .fill(membersByRow[index].contains(tag) ? (colors[tag] ?? .plannerAccent) : Color.secondary.opacity(0.16))
                                    .frame(width: 10, height: 10)
                                    .frame(width: columnWidth, height: rowHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }.scrollIndicators(.visible)
        }.frame(height: headerHeight + rowHeight * CGFloat(rows.count))
    }

    private func tagHeader(_ id: UUID) -> some View {
        let name = names[id] ?? "標籤"
        return Button { openTag(id) } label: {
            Text(name).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                .lineLimit(3).minimumScaleFactor(0.8).padding(.horizontal, 4)
                .frame(width: columnWidth, height: headerHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(colors[id] ?? .plannerAccent)
            .accessibilityLabel(name)
            .accessibilityHint("查看這個標籤的所有成員")
    }
}

private struct DiagramViewport: View {
    private struct Contour {
        let tags: [UUID]
        let path: Path
    }

    let layout: ContactSetLayout
    let regions: [ContactSetMap.Region]
    let colors: [UUID: Color]
    let names: [UUID: String]
    let openTag: (UUID) -> Void
    let openResult: (ContactMapSelection) -> Void
    @State private var overlappingOutlines: [UUID] = []
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        let scale = clamped(zoom * magnification)
        let height: CGFloat = 254 * scale
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                plot(size: CGSize(width: proxy.size.width * scale, height: height))
            }
        }
        .frame(height: height)
        .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
            state = value.magnification
        }.onEnded { zoom = clamped(zoom * $0.magnification) })
        .confirmationDialog("查看哪個標籤？", isPresented: Binding(get: { !overlappingOutlines.isEmpty }, set: {
            if !$0 { overlappingOutlines.removeAll() }
        }), titleVisibility: .visible, presenting: overlappingOutlines) { choices in
            ForEach(choices, id: \.self) { id in
                Button(names[id] ?? "標籤") { openTag(id) }
            }
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(2.4, max(1, value)) }

    private func plot(size: CGSize) -> some View {
        let contours = layout.outlines.map { Contour(tags: $0.tags, path: $0.path(in: size)) }
        return ZStack {
            Canvas { context, _ in
                for contour in contours {
                    let color = contour.tags.first.flatMap { colors[$0] } ?? .plannerAccent
                    context.fill(contour.path, with: .color(color.opacity(0.16)))
                }
                for contour in contours {
                    let color = contour.tags.first.flatMap { colors[$0] } ?? .plannerAccent
                    context.stroke(contour.path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
            .accessibilityHidden(true)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { openOutline(at: $0.location, contours: contours) })
            ForEach(regions) { region in
                if let point = layout.points[region.tags] {
                    Button { openResult(.exact(region.tags)) } label: {
                        Text("\(region.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44)
                            .background(.regularMaterial, in: Capsule()).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("只在 \(tagNames(region.tags, in: names))，\(region.count) 人")
                        .position(x: point.x * size.width, y: point.y * size.height)
                }
            }
        }.frame(width: size.width, height: size.height)
    }

    private func openOutline(at point: CGPoint, contours: [Contour]) {
        for width: CGFloat in [10, 28] {
            let hits = contours.flatMap { contour -> [UUID] in
                let stroke = contour.path.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round,
                                                      miterLimit: 2, transform: .identity)
                return stroke.contains(point) ? contour.tags : []
            }
            guard let first = hits.first else { continue }
            if hits.count == 1 { openTag(first) }
            else { overlappingOutlines = hits }
            return
        }
    }
}

private func tagNames(_ ids: [UUID], in names: [UUID: String]) -> String {
    ids.compactMap { names[$0] }.joined(separator: " ＋ ")
}

struct ContactSetResults: View {
    let title: String
    var excludesOtherCircles = false
    let people: [Contact]
    @State private var selection = ContactSelection()

    var body: some View {
        ContactPeopleList(people: people, selection: $selection)
            .safeAreaInset(edge: .top, spacing: 0) {
                if excludesOtherCircles {
                    Text("排除圖中的其他圈").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 6)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button(selection.active ? "取消選取" : "選取") { selection = ContactSelection(active: !selection.active) }
                    .disabled(people.isEmpty && !selection.active)
            }
    }
}
