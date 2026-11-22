import AppKit
import SwiftUI
import Observation
import PlinthLoyalty
import PlinthSettings
import PlinthSync

/// Lets SwiftUI views refresh when the loyalty ledger changes.
@MainActor @Observable final class LoyaltyModel {
    private(set) var revision = 0
    func bump() { revision += 1 }
}

extension Color {
    init(hexString: String) {
        let v = UInt32(hexString.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension AccentChoice {
    /// The level that unlocks this accent: the colourway accents unlock with their level, the rest are free.
    var unlockLevel: Int { LoyaltyColourway.named(rawValue)?.unlockLevel ?? 1 }

    /// The accent actually in use at `level`. A brand colour the level has not unlocked falls back to
    /// the default blue (it could only have been chosen before points were reset, or on the Mac app).
    /// With no level known yet (before loyalty is set up), the choice stands, as on the Mac.
    func effective(atLevel level: Int?) -> AccentChoice {
        guard unlockLevel > 1, let level, unlockLevel > level else { return self }
        return .blue
    }
}

/// What the app looks like at a loyalty tick, reduced to what earns points. Nothing here names a page.
struct LoyaltySnapshot: Equatable {
    /// The key window is a private window: a day of use is not counted from one.
    var keyWindowIsPrivate = false
    var hasPins = false
    /// An ordinary (not private) window has a split view on.
    var hasSplitInOrdinaryWindow = false
    var hasBookmarks = false
    var syncIsOn = false
}

/// Maps the app's state to the loyalty events it earns, as the Mac app does. The Chromium build has
/// no Ask yet, so the first-Ask milestone cannot be reached here.
enum LoyaltyEarning {
    /// The events for one tick (at launch, on activation and every few seconds while Plinth is active).
    /// Repeats are free: the engine pays a day once and a milestone once.
    static func tickEvents(_ s: LoyaltySnapshot) -> [LoyaltyEvent] {
        var events: [LoyaltyEvent] = []
        if !s.keyWindowIsPrivate { events.append(.dayOfUse) }
        if s.hasPins { events.append(.milestone(.firstPin)) }
        if s.hasSplitInOrdinaryWindow { events.append(.milestone(.firstSplitView)) }
        if s.hasBookmarks { events.append(.milestone(.firstBookmark)) }
        if s.syncIsOn { events.append(.milestone(.syncOn)) }
        return events
    }

    /// The colourway a level unlocks, if any (level 1's Sunrise is always there, so it is not an unlock).
    static func unlock(for level: LoyaltyLevel) -> LoyaltyColourway? {
        LoyaltyColourway.all.first { $0.unlockLevel == level.number && $0.unlockLevel > 1 }
    }
}

/// Points and levels for this app: the engine, the model views observe, and the share sheet.
/// The ledger is `loyalty.json` in the app's storage directory, as on the Mac, and syncs with iCloud sync
/// (see Sync.swift).
@MainActor final class LoyaltyController {
    let engine: LoyaltyEngine
    let model = LoyaltyModel()
    /// During the first minute of the first run, level-ups are acknowledged without a card.
    var silentUntil: Date?
    /// Runs the share sheet for the loyalty card; held here so it outlives the Settings window.
    let cardSharer: ShareCardSharer

    init(engine: LoyaltyEngine, onShared: @escaping () -> Void) {
        self.engine = engine
        cardSharer = ShareCardSharer(onShared: onShared)
    }
}

extension ChromiumApp {
    // MARK: Setup

    /// A launch with `PLINTH_STORAGE` is a scratch profile: it never uses the real device ID.
    var isScratchProfile: Bool { ProcessInfo.processInfo.environment["PLINTH_STORAGE"] != nil }

    /// The current level, or nil before loyalty is set up.
    var loyaltyLevel: Int? {
        guard let loyalty else { return nil }
        _ = loyalty.model.revision   // observed, so the chrome follows a level change
        return loyalty.engine.totals.level.number
    }

    func setUpLoyalty() {
        let file = storageDirectory.appendingPathComponent("loyalty.json")
        let firstRun = !FileManager.default.fileExists(atPath: file.path)
        let engine = LoyaltyEngine(deviceID: isScratchProfile ? "scratch-profile" : SyncSettings().deviceID, platform: .mac, fileURL: file)
        loyalty = LoyaltyController(engine: engine) { [weak self] in self?.earn(.share) }
        // The first run credits what already exists (pins, a day of use) without a level-up card.
        if firstRun { loyalty.silentUntil = Date().addingTimeInterval(60) }
        engine.onChange = { [weak self] in
            guard let self else { return }
            self.loyalty.model.bump()
            self.pushLoyaltyToSync()
            self.applyAppIcon()
            self.announceLevelUpIfPossible()
        }
        settings.observe { [weak self] old, new in
            if old.appIcon != new.appIcon { self?.applyAppIcon() }
        }
        ShareCard.removeLeftovers()
        applyAppIcon()
        loyaltyTick()
    }

    /// Records an event. A level-up shows the level-up card (see `announceLevelUpIfPossible`).
    func earn(_ event: LoyaltyEvent) { loyalty?.engine.record(event) }

    /// Plinth became the active app: count the day and show a level-up that was waiting.
    func loyaltyDidBecomeActive() {
        guard loyalty != nil else { return }
        earnDayOfUse()
        announceLevelUpIfPossible()
    }

    /// One use per day, not from a private window.
    func earnDayOfUse() {
        guard loyalty != nil, !(keyWindowID.map { store.isPrivate(window: $0) } ?? false) else { return }
        earn(.dayOfUse)
    }

    /// Called every few seconds while Plinth is active: counts the day (so one is not missed if Plinth
    /// stays frontmost across midnight) and credits one-off milestones. Private windows do not count.
    func loyaltyTick() {
        guard let loyalty, loyalty.engine.isEnabled else { return }
        let snapshot = LoyaltySnapshot(
            keyWindowIsPrivate: keyWindowID.map { store.isPrivate(window: $0) } ?? false,
            hasPins: !store.pins.isEmpty,
            hasSplitInOrdinaryWindow: store.windows.contains { !$0.isPrivate && $0.split != nil },
            hasBookmarks: !(bookmarks?.bookmarks.isEmpty ?? true),
            syncIsOn: sync != nil)
        for event in LoyaltyEarning.tickEvents(snapshot) { earn(event) }
        announceLevelUpIfPossible()   // a level reached before Plinth was active waits for the next tick
    }

    /// Shows the level-up card only when Plinth is the active app. Otherwise the level stays
    /// unannounced and is shown at the next change or tick that finds it possible. Levels reached
    /// during the first minute of the first run are acknowledged silently.
    func announceLevelUpIfPossible() {
        guard let loyalty else { return }
        if let until = loyalty.silentUntil, Date() < until { _ = loyalty.engine.claimLevelUp(); return }
        guard NSApp.isActive else { return }
        if let level = loyalty.engine.claimLevelUp() { LoyaltyToast.show(level: level) }
    }
}

// MARK: - Badge

/// The level badge: the arch from the logo with the level number, in the colourway's colours.
struct LoyaltyBadge: View {
    var level: LoyaltyLevel
    var colourway: LoyaltyColourway = .sunrise
    var size: CGFloat = 56

    var body: some View {
        let sky = colourway.sky.map { Color(hexString: $0) }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(Color(hexString: colourway.tile))
            ArchShape()
                .fill(LinearGradient(colors: sky.count > 1 ? sky : [sky[0], sky[0]], startPoint: .top, endPoint: .bottom))
                .overlay(ArchShape().stroke(Color(hexString: colourway.frame), lineWidth: size * 0.04))
                .frame(width: size * 0.5, height: size * 0.52)
                .offset(y: -size * 0.04)
            Text("\(level.number)").font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hexString: colourway.id == "mono" ? "#FFFFFF" : colourway.frame))
                .offset(y: size * 0.1)
            VStack { Spacer(); RoundedRectangle(cornerRadius: size * 0.02).fill(Color(hexString: colourway.frame)).frame(width: size * 0.62, height: size * 0.07) }
                .padding(.bottom, size * 0.12)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("Level \(level.number), \(level.name)")
    }
}

struct ArchShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Level-up card

/// A small card near the bottom of the screen that fades in, stays a few seconds and fades out.
/// It is its own panel, above the pages' Chromium windows, and never takes a click.
@MainActor enum LoyaltyToast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?
    private static var resignObserver: NSObjectProtocol?

    /// Takes the card away at once (Plinth stopped being the active app).
    static func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    static func show(level: LoyaltyLevel) {
        dismiss()   // also removes the previous resign observer
        let host = NSHostingView(rootView: LevelUpCard(level: level, unlock: LoyaltyEarning.unlock(for: level)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.contentView = host
        if let screen = (NSApp.keyWindow?.screen ?? NSScreen.main) {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - host.frame.width / 2, y: f.minY + 110))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()   // only called while Plinth is the active app (see announceLevelUpIfPossible)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
        panel = p
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LoyaltyToast.dismiss() }
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}

private struct LevelUpCard: View {
    var level: LoyaltyLevel
    var unlock: LoyaltyColourway?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let surface = dark ? Color(hexString: "#1B1A2E") : .white
        let border = dark ? Color.white.opacity(0.14) : Color(hexString: "#E3DCCB")
        let primary = dark ? Color(hexString: "#F4EEE6") : Color(hexString: "#1C1C1A")
        let secondary = dark ? Color(hexString: "#F4EEE6").opacity(0.7) : Color(hexString: "#4A4A45")
        HStack(spacing: 14) {
            LoyaltyBadge(level: level, colourway: unlock ?? .sunrise, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Level \(level.number): \(level.name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(primary)
                Text(unlock.map { "\($0.name) app icon and accent unlocked" } ?? "Keep going")
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(surface)
            .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(border, lineWidth: 1))
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
