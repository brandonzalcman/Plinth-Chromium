import Foundation
import Testing
import PlinthModel
import PlinthRules
import PlinthFade
import PlinthStore
import PlinthSync
@testable import PlinthChromiumApp

@Suite struct SyncGateTests {
    @Test func offUnlessTurnedOn() {
        #expect(SyncGate.state(enabled: false, containers: [SyncGate.container]) == .off)
        #expect(SyncGate.state(enabled: false, containers: nil) == .off)
    }

    @Test func theAdHocBuildNeedsASignedBuild() {
        #expect(SyncGate.state(enabled: true, containers: nil) == .needsSignedBuild)
        #expect(SyncGate.state(enabled: true, containers: []) == .needsSignedBuild)
        #expect(!SyncGate.canSync(containers: nil))
        #expect(SyncGate.explanation(.needsSignedBuild).hasPrefix("iCloud needs a signed build"))
    }

    @Test func onlyPlinthsContainerWillDo() {
        #expect(SyncGate.state(enabled: true, containers: ["iCloud.com.example.other"]) == .wrongContainer(found: ["iCloud.com.example.other"]))
        #expect(SyncGate.state(enabled: true, containers: ["iCloud.com.example.other", "iCloud.dev.getplinth.Plinth"])
                == .ready(container: "iCloud.dev.getplinth.Plinth"))
        #expect(SyncGate.canSync(containers: ["iCloud.dev.getplinth.Plinth"]))
    }

    @Test func theInMemoryServerNeedsNoEntitlement() {
        #expect(SyncGate.state(enabled: true, containers: nil, inMemory: true) == .inMemory)
    }

    @Test func testsRunWithoutTheEntitlement() {
        // The test runner is not signed for iCloud, as the ad-hoc app isn't: the gate must say so, not crash.
        #expect(SyncGate.entitledContainers()?.contains(SyncGate.container) != true)
    }
}

/// Two devices on one in-memory server, wired to their stores the way the app wires its own.
@MainActor
@Suite struct SyncWiringTests {
    struct NoFade: FadeEvaluating {
        func evaluate(sites: [Site], stats: [SiteKey: Usage], visible: Set<PageID>, now: Date) -> FadeVerdict { FadeVerdict() }
    }

    func makeStore() -> BrowserStore {
        BrowserStore(identity: SiteIdentity(), namer: PageNamer(), fader: NoFade(), storageDirectory: nil)
    }

    @Test func pinsHistoryAndOpenPagesReachTheOtherDevice() async throws {
        let server = InMemoryTransport()
        let mac = makeStore(), other = makeStore()
        let window = mac.createWindow()
        _ = other.createWindow()
        mac.openPage(url: URL(string: "https://swift.org/")!, in: window)
        let site = try #require(mac.window(window)?.sites.first)
        mac.pin(site: site.id)
        mac.openPage(url: URL(string: "https://example.com/reading")!, in: window)

        let macSync = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "mac", deviceName: "This Mac", stateURL: nil))
        let otherSync = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "other", deviceName: "Other Mac", stateURL: nil))
        guard case .success = await SyncWiring.syncNow(macSync, store: mac) else { Issue.record("first sync failed"); return }
        guard case .success(let devices) = await SyncWiring.syncNow(otherSync, store: other) else { Issue.record("second sync failed"); return }

        #expect(other.pins.map(\.key.host) == ["swift.org"])
        #expect(Set(other.history.map { $0.url.host ?? "" }).isSuperset(of: ["swift.org", "example.com"]))
        let pages = devices.first { $0.deviceID == "mac" }?.pages.map(\.url.host) ?? []
        #expect(pages.contains("example.com"))
    }

    @Test func clearingHistoryReachesTheOtherDevice() async {
        let server = InMemoryTransport()
        let mac = makeStore(), other = makeStore()
        let window = mac.createWindow()
        mac.openPage(url: URL(string: "https://swift.org/")!, in: window)
        let macSync = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "mac", deviceName: "This Mac", stateURL: nil))
        let otherSync = SyncCoordinator(engine: SyncEngine(transport: server, deviceID: "other", deviceName: "Other Mac", stateURL: nil))
        await SyncWiring.syncNow(macSync, store: mac)
        await SyncWiring.syncNow(otherSync, store: other)
        #expect(!other.history.isEmpty)

        // As ChromiumApp.clearHistory(since: nil) does it.
        mac.clearHistory(since: nil)
        macSync.engine.clearHistory()
        await SyncWiring.syncNow(macSync, store: mac)
        await SyncWiring.syncNow(otherSync, store: other)
        #expect(other.history.isEmpty)
    }
}

@Suite struct FeatureLoyaltyTests {
    @Test func bookmarksAndSyncEarnTheirMilestones() {
        let events = LoyaltyEarning.tickEvents(LoyaltySnapshot(hasBookmarks: true, syncIsOn: true))
        #expect(events.contains(.milestone(.firstBookmark)))
        #expect(events.contains(.milestone(.syncOn)))
        #expect(!LoyaltyEarning.tickEvents(LoyaltySnapshot()).contains(.milestone(.firstBookmark)))
    }
}

@Suite struct PasswordScriptTests {
    @Test func theScriptIsAFunctionThatReturnsItsFill() {
        let source = ChromiumPasswordScript.source.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(source.hasPrefix("(function (post, testMode) {"))
        #expect(source.hasSuffix("})"))
        #expect(source.contains("return fill;"))
        // Nothing the page could reach: no WebKit handler, nothing hung on window.
        #expect(!source.contains("messageHandlers"))
        #expect(!source.contains("window.__plinth"))
    }

    @Test func scriptedStepsQuoteTheirArguments() {
        #expect(DebugSteps.jsString("#user") == "\"#user\"")
        #expect(DebugSteps.jsString("a\"b") == "\"a\\\"b\"")
    }
}
