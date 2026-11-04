import AppKit
import QuartzCore

func quietly(_ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
}

extension CALayer {
    /// Starts `animation` now, repeating forever, `offset` seconds into its cycle.
    func loop(_ animation: CAAnimation, key: String, offset: Double = 0) {
        animation.repeatCount = .infinity
        animation.beginTime = convertTime(CACurrentMediaTime(), from: nil)
        animation.timeOffset = offset
        animation.isRemovedOnCompletion = false
        add(animation, forKey: key)
    }
}

func shape(_ path: CGPath, fill: NSColor? = nil, stroke: NSColor? = .black, width: CGFloat = 1, in parent: CALayer) -> CAShapeLayer {
    let layer = CAShapeLayer()
    layer.path = path
    layer.fillColor = fill?.cgColor
    layer.strokeColor = stroke?.cgColor
    layer.lineWidth = stroke == nil ? 0 : width
    layer.lineCap = .round
    layer.lineJoin = .round
    parent.addSublayer(layer)
    return layer
}

func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil)
}

/// An arc of a Wi-Fi wave whose top sits at the origin.
func wave(radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: 0, y: radius), radius: radius, startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false)
    return path
}
