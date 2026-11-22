import Foundation
import Testing
import PlinthModel
import PlinthSidebar
@testable import PlinthChromiumApp

@Suite struct ContentGeometryTests {
    let size = CGSize(width: 1280, height: 820)

    @Test func dockLeavesRoomForTheBarAndTheTitlebar() {
        let g = ContentGeometry(layout: .dock)
        let page = g.pageFrame(in: size)
        #expect(page.minY == ContentGeometry.dockHeight + ContentGeometry.margin)
        #expect(page.maxY == size.height - ContentGeometry.titlebarHeight)
        #expect(page.minX == ContentGeometry.margin)
        #expect(page.maxX == size.width - ContentGeometry.margin)
    }

    @Test func sidebarAndRailTakeTheLeftColumn() {
        let full = ContentGeometry(layout: .sidebar).pageFrame(in: size)
        #expect(full.minX == ContentGeometry.sidebarWidth)
        #expect(full.maxY == size.height - ContentGeometry.margin)
        let rail = ContentGeometry(layout: .sidebar, sidebarCollapsed: true).pageFrame(in: size)
        #expect(rail.minX == ContentGeometry.railWidth)
        // The rail is narrower than the traffic lights, so the page starts below them.
        #expect(rail.maxY == size.height - ContentGeometry.titlebarHeight)
        // Collapsing only matters in the sidebar layout.
        #expect(ContentGeometry(layout: .dock, sidebarCollapsed: true).sidebarColumnWidth == 0)
    }

    @Test func fullScreenPagesFillTheWindow() {
        for layout in TabLayout.allCases {
            let g = ContentGeometry(layout: layout, chromeHidden: true)
            #expect(g.pageFrame(in: size) == CGRect(origin: .zero, size: size))
            #expect(g.cornerRadius == 0)
        }
    }

    @Test func splitPanesShareThePageWithAGap() {
        let g = ContentGeometry(layout: .dock)
        let page = g.pageFrame(in: size)
        let (left, right) = g.splitFrames(in: size, fraction: 0.5)
        #expect(left.minX == page.minX)
        #expect(right.maxX == page.maxX)
        #expect(right.minX - left.maxX == ContentGeometry.margin)
        #expect(abs(left.width - right.width) <= 1)
        // The fraction is clamped like the Mac app's split (0.2...0.8).
        let (narrow, _) = g.splitFrames(in: size, fraction: 0.01)
        #expect(narrow.width >= (page.width - ContentGeometry.margin) * 0.2 - 1)
    }

    @Test func tinyWindowsNeverGetNegativeFrames() {
        let page = ContentGeometry(layout: .sidebar).pageFrame(in: CGSize(width: 100, height: 50))
        #expect(page.width >= 0 && page.height >= 0)
    }
}

@MainActor
@Suite struct ShellPreferencesTests {
    @Test func defaultsToTheDockAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plinth-prefs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ShellPreferencesStore(directory: dir)
        #expect(store.value.tabLayout == .dock)
        var seen: [TabLayout] = []
        store.observe { _, new in seen.append(new.tabLayout) }
        store.update { $0.tabLayout = .sidebar; $0.sidebarCollapsed = true }
        store.update { $0.tabLayout = .sidebar }   // no change, no notification
        #expect(seen == [.sidebar])
        let reloaded = ShellPreferencesStore(directory: dir)
        #expect(reloaded.value.tabLayout == .sidebar)
        #expect(reloaded.value.sidebarCollapsed)
    }

    @Test func unknownValuesFallBackToDefaults() throws {
        let json = #"{"tabLayout":"floating","sidebarCollapsed":"yes"}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(ShellPreferences.self, from: json)
        #expect(prefs.tabLayout == .dock)
        #expect(prefs.sidebarCollapsed == false)
    }
}
