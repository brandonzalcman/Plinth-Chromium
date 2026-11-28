import AppKit
import AVFoundation
import AVKit

/// One video the page couldn't play, drawn by macOS (AVFoundation) in a small borderless window over its
/// place in the page. The window is a child of the page's own window, so it moves and hides with it. It is
/// cut to the visible part of the video with the page's rounded corners, uses macOS's floating controls,
/// fades in once the first frame is ready, and autoplays (muted, as the page asked) while it is on screen.
@MainActor
final class NativeVideoLayer: NSObject {
    let id: Int
    let url: URL
    private let window: NativeVideoWindow
    private let clip = NSView()
    private let playerView: NativeVideoPlayerView
    private let player: AVPlayer
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private weak var host: NSWindow?
    private var frame: NativeVideoFrame
    private var shown = false
    private var ready = false
    /// The person paused it with the controls: autoplay leaves it alone until they play it again.
    private var pausedByPerson = false
    /// Plinth paused it itself (scrolled away): don't take that for the person's pause.
    private var pausingItself = false
    /// True once it has played: it no longer autoplays on its own after the person has seen it.
    private var hasPlayed = false

    /// Scrolling over the video scrolls the page: `point` is in the page view's points (top-left origin).
    var onScroll: ((_ point: NSPoint, _ deltaX: CGFloat, _ deltaY: CGFloat) -> Void)?

    init(frame: NativeVideoFrame) {
        id = frame.id
        url = frame.url
        self.frame = frame
        var options: [String: Any] = [:]
        if let page = frame.page { options["AVURLAssetHTTPHeaderFieldsKey"] = ["Referer": page.absoluteString] }
        let item = AVPlayerItem(asset: AVURLAsset(url: frame.url, options: options))
        player = AVPlayer(playerItem: item)
        player.isMuted = frame.muted
        player.preventsDisplaySleepDuringVideoPlayback = true
        playerView = NativeVideoPlayerView()
        window = NativeVideoWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.identifier = NSUserInterfaceItemIdentifier("plinth.native-video")

        clip.wantsLayer = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        window.contentView = clip

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.videoGravity = frame.fill ? .resizeAspectFill : .resizeAspect
        playerView.wantsLayer = true
        playerView.onScroll = { [weak self] event in self?.forwardScroll(event) }
        clip.addSubview(playerView)

        observations.append(playerView.observe(\.isReadyForDisplay, options: [.new]) { [weak self] view, _ in
            let ready = view.isReadyForDisplay
            Task { @MainActor in if ready { self?.becameReady() } }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.playbackChanged(status) }
        })
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd() }
        }
    }

    /// Places it over the page view of `host` (the page's own window), or hides it when off screen.
    func update(_ frame: NativeVideoFrame, host: NSWindow, pageVisible: Bool) {
        self.frame = frame
        self.host = host
        playerView.videoGravity = frame.fill ? .resizeAspectFill : .resizeAspect
        guard pageVisible, !frame.hidden, host.isVisible, let content = host.contentView,
              let placement = NativeVideoPlacement.place(frame, pageSize: content.bounds.size) else {
            hide()
            return
        }
        // The page view's top-left origin to the screen's bottom-left one.
        let page = host.convertToScreen(content.convert(content.bounds, to: nil))
        let windowFrame = NSRect(x: page.minX + placement.visible.minX, y: page.maxY - placement.visible.maxY,
                                 width: placement.visible.width, height: placement.visible.height)
        if window.frame != windowFrame { window.setFrame(windowFrame, display: true) }
        // The player keeps the whole video's size; the clip view cuts it to the visible part.
        playerView.frame = NSRect(x: placement.player.minX,
                                  y: placement.visible.height - placement.player.maxY,
                                  width: placement.player.width, height: placement.player.height)
        clip.layer?.cornerRadius = placement.shownFraction >= 0.999 ? frame.radius : min(frame.radius, 4)
        if window.parent !== host {
            window.parent?.removeChildWindow(window)
            host.addChildWindow(window, ordered: .above)
        }
        if !shown {
            shown = true
            window.orderFront(nil)
            if ready { fadeIn() }
        }
        autoplay(shownFraction: placement.shownFraction)
    }

    /// For the "videos" debug step.
    var debugState: String {
        let status = ["paused", "waiting", "playing"][min(2, player.timeControlStatus.rawValue)]
        let item = player.currentItem
        return "#\(id) \(status) t=\(String(format: "%.1f", player.currentTime().seconds)) ready=\(ready) shown=\(shown) "
            + "muted=\(player.isMuted) item=\(item?.status.rawValue ?? -1) err=\(item?.error?.localizedDescription ?? "-") frame=\(window.frame)"
    }

    func hide() {
        guard shown else { return }
        shown = false
        pauseItself()
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    func close() {
        hide()
        player.pause()
        player.replaceCurrentItem(with: nil)
        observations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        window.close()
    }

    // MARK: Playback

    private func becameReady() {
        guard !ready else { return }
        ready = true
        if shown { fadeIn() }
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            window.animator().alphaValue = 1
        }
    }

    /// Plays while most of it is on screen and pauses when it scrolls away, like the sites do themselves.
    private func autoplay(shownFraction: CGFloat) {
        if shownFraction < 0.25 {
            if player.timeControlStatus != .paused { pauseItself() }
        } else if shownFraction >= 0.5, frame.autoplay || hasPlayed, !pausedByPerson,
                  player.timeControlStatus == .paused {
            player.play()
        }
    }

    private func pauseItself() {
        guard player.timeControlStatus != .paused else { return }
        pausingItself = true
        player.pause()
    }

    private func playbackChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            hasPlayed = true
            pausedByPerson = false
        case .paused:
            if pausingItself { pausingItself = false } else if hasPlayed { pausedByPerson = true }
        default: break
        }
    }

    private func reachedEnd() {
        if frame.loop {
            player.seek(to: .zero)
            player.play()
        } else {
            // Like the sites: the person decides whether to watch it again.
            pausedByPerson = true
        }
    }

    private func forwardScroll(_ event: NSEvent) {
        guard let host, let content = host.contentView else { return }
        let page = host.convertToScreen(content.convert(content.bounds, to: nil))
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let point = NSPoint(x: screen.x - page.minX, y: page.maxY - screen.y)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        onScroll?(point, event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
    }
}

/// The borderless window a native video sits in. It never becomes key, so the page keeps keyboard focus.
final class NativeVideoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// AVKit's player view, handing scrolling on to the page instead of keeping it.
final class NativeVideoPlayerView: AVPlayerView {
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}
