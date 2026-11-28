import AppKit
import Testing
@testable import Phosphor

@Suite struct CRTIconTests {
    @Test func menuIconIs18PointsWithOneAndTwoXReps() {
        let image = CRTIcon.image(fill: 0.6, band: .green)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate == false)

        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let pixels = Set(bitmaps.map { "\($0.pixelsWide)x\($0.pixelsHigh)" })
        #expect(pixels.contains("18x18"))
        #expect(pixels.contains("36x36"))
        for rep in bitmaps {
            #expect(rep.size == NSSize(width: 18, height: 18))
        }
    }
}
