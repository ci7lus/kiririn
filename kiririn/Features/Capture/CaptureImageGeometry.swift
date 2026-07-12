import CoreGraphics

enum CaptureImageGeometry {
    nonisolated static func bitmapFrame(fromTopLeft frame: CGRect, canvasHeight: CGFloat) -> CGRect
    {
        CGRect(
            x: frame.minX,
            y: canvasHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}
