import SwiftUI

/// Keep earlier items in place while revealing another batch at the bottom.
/// Only visible tiles decode thumbnails; the full collection remains available for jumps.
struct ContinuousMediaList<Data: RandomAccessCollection, ID: Hashable, Tile: View>: View {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let selectedID: ID?
    var columns = 1
    var spacing: CGFloat = 10
    @ViewBuilder let tile: (Data.Element) -> Tile

    @Namespace private var scrollSpace
    @State private var visibleCount = 120
    @State private var scrollRequest = 0
    private let batchSize = 120
    private var ids: [ID] { data.map { $0[keyPath: id] } }
    private var displayedCount: Int { min(visibleCount, data.count) }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: spacing) {
                            ForEach(data.prefix(displayedCount), id: id) { item in
                                tile(item).id(item[keyPath: id])
                            }
                        }.padding(10)
                        Color.clear.frame(height: 1)
                            .background {
                                GeometryReader { marker in
                                    Color.clear.preference(key: MediaListBottomKey.self, value: MediaListBottom(
                                        count: displayedCount,
                                        y: marker.frame(in: .named(scrollSpace)).maxY
                                    ))
                                }
                            }
                    }
                }
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(MediaListBottomKey.self) { bottom in
                    guard let bottom, bottom.count == displayedCount,
                          bottom.y > 0, bottom.y <= viewport.size.height + 1,
                          displayedCount < data.count else { return }
                    visibleCount = min(displayedCount + batchSize, data.count)
                }
                .onChange(of: ids) { _, _ in
                    // Search, sorting, and folder changes must not retain an old page offset.
                    visibleCount = batchSize
                    revealSelection()
                }
                .onChange(of: selectedID, initial: true) { _, _ in revealSelection() }
                .task(id: scrollRequest) {
                    // The target may be in the newly added batch. Let SwiftUI install its ID first.
                    await Task.yield()
                    guard !Task.isCancelled, let selectedID else { return }
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private func revealSelection() {
        if let selectedID, let offset = ids.firstIndex(of: selectedID) {
            visibleCount = max(visibleCount, min((offset / batchSize + 1) * batchSize, data.count))
        }
        scrollRequest += 1
    }
}

private struct MediaListBottom: Equatable {
    let count: Int
    let y: CGFloat
}

private struct MediaListBottomKey: PreferenceKey {
    static var defaultValue: MediaListBottom? { nil }
    static func reduce(value: inout MediaListBottom?, nextValue: () -> MediaListBottom?) {
        if let next = nextValue() { value = next }
    }
}
