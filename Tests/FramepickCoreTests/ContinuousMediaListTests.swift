import XCTest
import SwiftUI
import AppKit
@testable import Framepick

@MainActor
private final class MediaListFixture: ObservableObject {
    @Published var items = Array(0..<253)
    @Published var selection: Int? = 0
    @Published var columns = 1
    var appeared: Set<Int> = []
}

private struct MediaListTestView: View {
    @ObservedObject var fixture: MediaListFixture
    var body: some View {
        ContinuousMediaList(data: fixture.items, id: \.self, selectedID: fixture.selection, columns: fixture.columns) { number in
            Text("Item \(number)").frame(maxWidth: .infinity).frame(height: 40)
                .onAppear { fixture.appeared.insert(number) }
        }
    }
}

final class ContinuousMediaListTests: XCTestCase {
    @MainActor
    private func host(_ fixture: MediaListFixture) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MediaListTestView(fixture: fixture))
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    @MainActor
    private func scrollToBottom(_ scroll: NSScrollView) {
        let end = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor
    func testScrollingAppendsBatchesKeepsEarlierItemsAndStopsAtEnd() async throws {
        try await checkAppending(columns: 1)
    }

    @MainActor
    func testTwoColumnScrollingReachesTheOddFinalItem() async throws {
        try await checkAppending(columns: 2)
    }

    @MainActor
    private func checkAppending(columns: Int) async throws {
        let fixture = MediaListFixture()
        fixture.columns = columns
        let window = host(fixture); defer { window.close() }
        try await settle()
        let scroll = try XCTUnwrap(findScroll(in: XCTUnwrap(window.contentView)))
        let firstHeight = try XCTUnwrap(scroll.documentView).bounds.height
        XCTAssertTrue(fixture.appeared.contains(0))
        XCTAssertFalse(fixture.appeared.contains(120), "Offscreen thumbnails should stay lazy")

        scrollToBottom(scroll)
        try await settle()
        let secondHeight = try XCTUnwrap(scroll.documentView).bounds.height
        XCTAssertGreaterThan(secondHeight, firstHeight + 1_000, "Reaching the bottom must append the next batch without a button")
        XCTAssertEqual(fixture.selection, 0, "Loading more must not change the selected photo/frame")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000, "Appending must not jump back to the top")

        scrollToBottom(scroll)
        try await settle()
        scrollToBottom(scroll)
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(252), "The partial final batch must be reachable")
        let finalHeight = try XCTUnwrap(scroll.documentView).bounds.height
        scrollToBottom(scroll)
        try await settle()
        XCTAssertEqual(scroll.documentView?.bounds.height ?? 0, finalHeight, accuracy: 1)

        fixture.appeared.removeAll()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(0), "Earlier batches must remain available when scrolling back")
    }

    @MainActor
    func testSelectionJumpsAcrossBatchesAndChangedResultsResetTheList() async throws {
        let fixture = MediaListFixture()
        fixture.columns = 2
        fixture.selection = 241
        let window = host(fixture); defer { window.close() }
        try await settle()
        let scroll = try XCTUnwrap(findScroll(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(fixture.appeared.contains(241), "Opening a later photo must reveal its initial selection")
        fixture.selection = 0
        try await settle()
        fixture.selection = 241
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(241), "A frame number jump must reveal and scroll to an unloaded item")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)

        fixture.selection = 119
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(119))
        fixture.selection = 120
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(120), "Keyboard navigation must cross batch boundaries")

        fixture.items = Array(1_000..<1_003)
        fixture.selection = 1_000
        try await settle()
        XCTAssertTrue(fixture.appeared.contains(1_000))
        XCTAssertLessThan(scroll.documentView?.bounds.height ?? .infinity, 400, "Filtering must discard the previous list extent")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)

        fixture.items = []; fixture.selection = nil
        try await settle()
        XCTAssertLessThan(scroll.documentView?.bounds.height ?? .infinity, 400)
    }
}
