import AppKit
import Testing
import PlinthSidebar
@testable import PlinthChromiumApp

@MainActor
@Suite struct SplitAndSnapshotTests {
    let size = CGSize(width: 1200, height: 800)

    @Test func theDividerSitsInTheGapAndDraggingItGivesBackTheSameFraction() {
        for layout in [TabLayout.dock, .sidebar] {
            let g = ContentGeometry(layout: layout)
            for f in [0.3, 0.5, 0.7] {
                let d = g.splitDivider(in: size, fraction: f)
                let (left, right) = g.splitFrames(in: size, fraction: f)
                #expect(d.minX == left.maxX)
                #expect(d.maxX == right.minX)
                let back: Double = g.splitFraction(forDividerAt: d.midX, in: size)
                #expect(abs(back - f) < 0.01)
            }
        }
    }

    @Test func draggingPastTheEdgesStopsAtAFifthOfTheWidth() {
        let g = ContentGeometry(layout: .dock)
        #expect(g.splitFraction(forDividerAt: 0, in: size) == 0.2)
        #expect(g.splitFraction(forDividerAt: size.width, in: size) == 0.8)
    }

    @Test func snapshotsAreScaledDownToTheShelfWidth() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(rep.representation(using: .jpeg, properties: [:]))
        let image = try #require(PageSnapshots.scaled(data))
        #expect(image.size.width == PageSnapshots.maxWidth)
        #expect(abs(image.size.height - PageSnapshots.maxWidth * 2 / 3) <= 1)
        #expect(PageSnapshots.jpeg(image) != nil)
    }
}
