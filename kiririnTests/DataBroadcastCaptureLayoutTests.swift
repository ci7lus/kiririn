import CoreGraphics
import Testing

@testable import kiririn

struct DataBroadcastCaptureLayoutTests {
    @Test func cropsLandscapeCaptureToStageBounds() throws {
        let layout = try #require(
            DataBroadcastCaptureLayout(
                sourceFrame: CGRect(x: 48.5, y: 0, width: 1920, height: 1080),
                videoFrame: CGRect(x: 640, y: 60, width: 1200, height: 675),
                outputHeight: 1080
            )
        )

        #expect(layout.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(layout.videoFrame == CGRect(x: 591.5, y: 60, width: 1200, height: 675))
    }

    @Test func cropsPortraitCaptureToLandscapeStageBounds() throws {
        let stageHeight = 559 * 9.0 / 16.0
        let stageFrame = CGRect(x: 0, y: (1080 - stageHeight) / 2, width: 559, height: stageHeight)
        let layout = try #require(
            DataBroadcastCaptureLayout(
                sourceFrame: stageFrame,
                videoFrame: stageFrame,
                outputHeight: 1080
            )
        )

        #expect(abs(layout.canvasSize.width - 1920) < 0.001)
        #expect(layout.canvasSize.height == 1080)
        #expect(layout.videoFrame.minX == 0)
        #expect(layout.videoFrame.minY == 0)
        #expect(abs(layout.videoFrame.width - 1920) < 0.001)
        #expect(layout.videoFrame.height == 1080)
    }
}
