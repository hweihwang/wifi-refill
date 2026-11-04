import AppKit
import QuartzCore

/// A view that draws in a fixed space, y down (the view is flipped), scaled to fit. Everything in it moves by Core Animation, so the render
/// server animates it and the app does no work between changes of the network.
@MainActor
public class Stage: NSView {
    let root = CALayer()
    let space: CGSize
    /// Reduce Motion: changes land at once, without transitions.
    public var still = false

    init(space: CGSize) {
        self.space = space
        super.init(frame: NSRect(origin: .zero, size: space))
        wantsLayer = true
        root.bounds = CGRect(origin: .zero, size: space)
        layer?.addSublayer(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let scale = min(bounds.width / space.width, bounds.height / space.height)
        quietly {
            root.position = CGPoint(x: bounds.midX, y: bounds.midY)
            root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        // Text is rasterised, at the screen's pixels per unit of the space.
        pixelsPerUnit = (window?.backingScaleFactor ?? 2) * scale
        for case let layer as CATextLayer in root.sublayersDeep { layer.contentsScale = pixelsPerUnit }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private(set) var pixelsPerUnit: CGFloat = 1

    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in parent: CALayer) -> CATextLayer {
        let layer = CATextLayer()
        layer.alignmentMode = .center
        layer.contentsScale = pixelsPerUnit
        parent.addSublayer(layer)
        set(layer, string, size: size, weight: weight, color: color)
        return layer
    }

    public override var isFlipped: Bool { true }
}

/// A four-pointed star.
func star(at point: CGPoint, size: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: point.x, y: point.y - size))
    path.addQuadCurve(to: CGPoint(x: point.x + size, y: point.y), control: point)
    path.addQuadCurve(to: CGPoint(x: point.x, y: point.y + size), control: point)
    path.addQuadCurve(to: CGPoint(x: point.x - size, y: point.y), control: point)
    path.addQuadCurve(to: CGPoint(x: point.x, y: point.y - size), control: point)
    return path
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

/// Sets a text layer's string and sizes it to fit, keeping its centre.
func set(_ layer: CATextLayer, _ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributed = NSAttributedString(string: string, attributes: [.font: roundedFont(size, weight), .foregroundColor: color])
    layer.string = attributed
    let measured = attributed.size()
    layer.bounds = CGRect(x: 0, y: 0, width: ceil(measured.width) + 4, height: ceil(measured.height))
}

/// A shape in the cup's own outline: dark brown ink, a line as thick as the icon's.
func outlined(_ path: CGPath, fill: NSColor? = nil, stroke: NSColor? = Palette.ink, width: CGFloat = Palette.line, in parent: CALayer) -> CAShapeLayer {
    shape(path, fill: fill, stroke: stroke, width: width, in: parent)
}

enum Palette {
    static let line: CGFloat = 11
    static let ink = NSColor(srgbRed: 0.29, green: 0.16, blue: 0.09, alpha: 1)
    static let cream = NSColor(srgbRed: 1, green: 0.985, blue: 0.965, alpha: 1)
    static let creamShade = NSColor(srgbRed: 0.95, green: 0.91, blue: 0.87, alpha: 1)
    static let chilly = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    static let chillyShade = NSColor(srgbRed: 0.82, green: 0.87, blue: 0.93, alpha: 1)
    static let wall = NSColor(srgbRed: 0.86, green: 0.79, blue: 0.72, alpha: 1)
    static let coffee = NSColor(srgbRed: 0.48, green: 0.26, blue: 0.13, alpha: 1)
    static let crema = NSColor(srgbRed: 0.69, green: 0.43, blue: 0.22, alpha: 1)
    static let blush = NSColor(srgbRed: 0.96, green: 0.6, blue: 0.56, alpha: 0.6)
    static let caramel = NSColor(srgbRed: 0.92, green: 0.56, blue: 0.30, alpha: 1)
    static let caramelDeep = NSColor(srgbRed: 0.71, green: 0.34, blue: 0.16, alpha: 1)
    static let sparkle = NSColor(srgbRed: 1, green: 0.8, blue: 0.35, alpha: 1)
    static let sweat = NSColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1)
}
