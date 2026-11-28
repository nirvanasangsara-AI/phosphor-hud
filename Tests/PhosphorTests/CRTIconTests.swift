import AppKit
import Testing
@testable import Phosphor

@Suite struct CRTIconTests {
    @Test func menuIconIs18PointsWithOneAndTwoXReps() {
        let image = CRTIcon.image(fill: 0.6, band: .green)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate == false)

        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let pixels = Set(bitmaps.map { ($0.pixelsWide, $0.pixelsHigh) })
        #expect(pixels.contains((18, 18)))
        #expect(pixels.contains((36, 36)))
        for rep in bitmaps {
            #expect(rep.size == NSSize(width: 18, height: 18))
        }
    }
}
