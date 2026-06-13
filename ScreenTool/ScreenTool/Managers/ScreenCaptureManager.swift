import UIKit
import ReplayKit

class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    /// Capture full screen via UIWindow hierarchy
    func captureScreen(in window: UIWindow) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Crop image to a polygon path
    func crop(image: UIImage, to path: UIBezierPath, in canvasSize: CGSize) -> UIImage? {
        let scale = image.size.width / canvasSize.width
        let scaledPath = UIBezierPath()

        // Scale path from canvas coords to image coords
        path.cgPath.applyWithBlock { element in
            let pts = element.points
            switch element.type {
            case .moveToPoint:
                scaledPath.move(to: CGPoint(x: pts[0].x * scale, y: pts[0].y * scale))
            case .addLineToPoint:
                scaledPath.addLine(to: CGPoint(x: pts[0].x * scale, y: pts[0].y * scale))
            case .addQuadCurveToPoint:
                scaledPath.addQuadCurve(
                    to: CGPoint(x: pts[1].x * scale, y: pts[1].y * scale),
                    controlPoint: CGPoint(x: pts[0].x * scale, y: pts[0].y * scale))
            case .addCurveToPoint:
                scaledPath.addCurve(
                    to: CGPoint(x: pts[2].x * scale, y: pts[2].y * scale),
                    controlPoint1: CGPoint(x: pts[0].x * scale, y: pts[0].y * scale),
                    controlPoint2: CGPoint(x: pts[1].x * scale, y: pts[1].y * scale))
            case .closeSubpath:
                scaledPath.close()
            @unknown default: break
            }
        }
        scaledPath.close()

        let bounds = scaledPath.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            scaledPath.addClip()
            image.draw(at: .zero)
        }
    }
}
