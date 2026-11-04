import AppKit
import QuartzCore
import RefillCore

/// The menu bar cup, breathing: one to three steam arcs for the signal, rising faster with more traffic, the cup filled
/// while Wi-Fi Refill keeps a cafe login, a drip while it refills, and a mark instead of steam when a leg is broken.
/// Drawn in layers on the status item's button, in the menu bar's own text colour.
@MainActor
public final class MenuBarCup {
    private weak var button: NSButton?
    private let cup = CALayer()
    private var body = CAShapeLayer()
    private var lines: [CAShapeLayer] = []
    private var wisps: [CAShapeLayer] = []
    private var mark: [CAShapeLayer] = []
    private var drip = CAShapeLayer()
    private var observation: NSKeyValueObservation?
    private var shown: (count: Int, pace: Int, mark: Bool, drip: Bool, filled: Bool, still: Bool)?

    public init(button: NSButton) {
        self.button = button
        button.wantsLayer = true
        button.image = nil
        cup.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        button.layer?.addSublayer(cup)

        let saucer = CGMutablePath()
        saucer.move(to: CGPoint(x: 2, y: 16.3))
        saucer.addLine(to: CGPoint(x: 15.5, y: 16.3))
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 3.2, y: 9))
        outline.addLine(to: CGPoint(x: 13.2, y: 9))
        outline.addCurve(to: CGPoint(x: 8.2, y: 14.6), control1: CGPoint(x: 13.2, y: 12.6), control2: CGPoint(x: 11.4, y: 14.6))
        outline.addCurve(to: CGPoint(x: 3.2, y: 9), control1: CGPoint(x: 5, y: 14.6), control2: CGPoint(x: 3.2, y: 12.6))
        outline.closeSubpath()
        let handle = CGMutablePath()
        handle.addArc(center: CGPoint(x: 13.6, y: 11), radius: 1.7, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        lines = [saucer, handle].map { shape($0, width: 1.3, in: cup) }
        body = shape(outline, width: 1.3, in: cup)
        for _ in 0..<3 {
            let wisp = shape(wave(radius: 2.2), width: 1.5, in: cup)
            wisp.opacity = 0
            wisps.append(wisp)
        }
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 8.2, y: 1.2))
        line.addLine(to: CGPoint(x: 8.2, y: 4.6))
        mark = [shape(line, width: 1.8, in: cup), shape(ellipse(8.2, 6.9, 1, 1), fill: .black, stroke: nil, in: cup)]
        drip = shape(ellipse(8.2, 1.7, 0.9, 1.2), fill: .black, stroke: nil, in: cup)
        recolor()
        observation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.recolor() }
        }
    }

    public func remove() {
        observation = nil
        cup.removeFromSuperlayer()
    }

    public func show(_ pulse: Pulse, filled: Bool, still: Bool) {
        if let button {
            quietly { cup.position = CGPoint(x: button.bounds.midX, y: button.bounds.midY) }
        }
        let broken = !pulse.isUp && pulse.state != .loggingIn && pulse.state != .paused
        let next = (count: pulse.isUp ? max(1, pulse.bars) : 0, pace: Int(pulse.busy * 3), mark: broken, drip: pulse.state == .loggingIn, filled: filled, still: still)
        if let shown, shown == next { return }
        shown = next
        quietly {
            mark.forEach { $0.isHidden = !next.mark }
            drip.isHidden = !next.drip
            body.fillColor = filled ? body.strokeColor : nil
        }
        let begin = cup.convertTime(CACurrentMediaTime(), from: nil)
        drip.removeAllAnimations()
        if next.drip, !still {
            let fall = CABasicAnimation(keyPath: "transform.translation.y")
            fall.fromValue = 0
            fall.toValue = 6
            fall.duration = 0.6
            drip.loop(fall, key: "fall")
        }
        let period = 2.6 - 1.6 * Double(next.pace) / 3
        for (index, wisp) in wisps.enumerated() {
            wisp.removeAllAnimations()
            guard index < next.count else {
                wisp.opacity = 0
                continue
            }
            let phase = Double(index) / Double(next.count)
            if still {
                // Reduce Motion: the arcs stand still, spread up the steam.
                quietly {
                    wisp.opacity = 1
                    wisp.path = wave(radius: 2.2 + phase * 2.6)
                    wisp.position = CGPoint(x: 8.2, y: 7 - phase * 5)
                }
                continue
            }
            wisp.opacity = 0
            wisp.position = CGPoint(x: 8.2, y: 0)
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = 8
            rise.toValue = 2
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = wave(radius: 2.2)
            grow.toValue = wave(radius: 4.8)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = (0...8).map { sin(Double($0) / 8 * .pi) }
            let group = CAAnimationGroup()
            group.animations = [rise, grow, fade]
            group.duration = period
            group.repeatCount = .infinity
            group.beginTime = begin
            group.timeOffset = phase * period
            wisp.add(group, forKey: "steam")
        }
    }

    private func recolor() {
        guard let button else { return }
        var color = NSColor.black.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        quietly {
            for layer in lines + wisps + [body] + mark { layer.strokeColor = color }
            for layer in [mark[1], drip] { layer.fillColor = color }
            if body.fillColor != nil { body.fillColor = color }
        }
    }
}
