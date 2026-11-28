import CoreGraphics
import Foundation
import Testing
@testable import PlinthChromiumApp

@Suite struct NativeVideoTests {
    func body(_ extra: [String: Any] = [:]) -> [AnyHashable: Any] {
        var b: [String: Any] = ["type": "video", "id": 3, "url": "https://video.twimg.com/amplify_video/1/vid/avc1/1280x720/a.mp4",
                                "page": "https://x.com/NASA", "x": 100, "y": 200, "w": 400, "h": 225,
                                "vw": 1000, "vh": 800, "radius": 16, "fill": false, "hidden": false,
                                "muted": true, "loop": false, "autoplay": true]
        for (k, v) in extra { b[k] = v }
        return b
    }

    @Test func readsAVideoReport() throws {
        guard case .video(let f) = try #require(NativeVideoMessage(body())) else { Issue.record("not a video"); return }
        #expect(f.id == 3 && f.muted && f.autoplay && !f.loop)
        #expect(f.rect == CGRect(x: 100, y: 200, width: 400, height: 225))
        #expect(f.radius == 16)
    }

    @Test func refusesFilesThatArentOnTheWeb() {
        #expect(NativeVideoMessage(body(["url": "file:///etc/passwd"])) == nil)
        #expect(NativeVideoMessage(body(["url": "javascript:alert(1)"])) == nil)
        #expect(NativeVideoMessage(body(["vw": 0])) == nil)
        #expect(NativeVideoMessage(["type": "nonsense"]) == nil)
        #expect(NativeVideoMessage(["type": "reset"]) == .reset)
        #expect(NativeVideoMessage(["type": "gone", "id": 7]) == .gone(id: 7))
    }

    @Test func placesTheVideoInPagePointsAtThePagesZoom() throws {
        guard case .video(let f) = try #require(NativeVideoMessage(body())) else { return }
        // The page view is 1500 points wide for a 1000 CSS-pixel viewport: 1.5 points per pixel.
        let p = try #require(NativeVideoPlacement.place(f, pageSize: CGSize(width: 1500, height: 1200)))
        #expect(p.visible == CGRect(x: 150, y: 300, width: 600, height: 338))
        #expect(p.shownFraction > 0.99)
    }

    @Test func cutsAVideoThatIsPartlyScrolledAway() throws {
        guard case .video(let f) = try #require(NativeVideoMessage(body(["y": -125]))) else { return }
        let p = try #require(NativeVideoPlacement.place(f, pageSize: CGSize(width: 1000, height: 800)))
        #expect(p.visible == CGRect(x: 100, y: 0, width: 400, height: 100))
        #expect(p.player.minY == -125)   // the player keeps its full size; the window shows its lower part
        #expect(abs(p.shownFraction - 100.0 / 225.0) < 0.01)
    }

    @Test func nothingWhenOffScreen() throws {
        guard case .video(let f) = try #require(NativeVideoMessage(body(["y": 900]))) else { return }
        #expect(NativeVideoPlacement.place(f, pageSize: CGSize(width: 1000, height: 800)) == nil)
    }

    @Test func theScriptStaysOutOfFramesAndOutOfTheWayWhenTheEngineCanPlayH264() {
        let s = NativeVideoScript.source
        #expect(s.contains("window.top !== window"))
        #expect(s.contains("isTypeSupported"))
        #expect(s.hasPrefix("(function (post)"))
    }
}
