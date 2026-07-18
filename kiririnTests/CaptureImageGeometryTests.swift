import CoreGraphics
import Testing

@testable import kiririn

struct CaptureImageGeometryTests {
    @Test func convertsTopLeftFrameToBitmapCoordinates() {
        let frame = CGRect(x: 120, y: 80, width: 640, height: 360)

        let converted = CaptureImageGeometry.bitmapFrame(
            fromTopLeft: frame,
            canvasHeight: 1080
        )

        #expect(converted == CGRect(x: 120, y: 640, width: 640, height: 360))
    }

    @Test func preservesFullCanvasFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let converted = CaptureImageGeometry.bitmapFrame(
            fromTopLeft: frame,
            canvasHeight: 1080
        )

        #expect(converted == frame)
    }
}
