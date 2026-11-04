import AppKit
import QuartzCore
import RefillCore

/// The cup from the app icon, alive on the desktop. Its steam is the Wi-Fi: one to three arcs for the signal, rising
/// faster the more the network carries. The coffee is the cafe's login session; a little kettle pours it again when
/// Wi-Fi Refill logs back in. When a leg breaks the steam stops and the cup says which.
@MainActor
public final class CupScene: Stage {
    enum Mood: Equatable { case calm, busy, worried, delighted, looksUp, sad }

    private let cup = CALayer()
    private let steam = CALayer()
    private var wisps: [(box: CALayer, outline: CAShapeLayer, color: CAShapeLayer)] = []
    private let tint = CAGradientLayer()
    private let coffee = CALayer()
    private var eyes: [CALayer] = []
    private var squints: [CAShapeLayer] = []
    private var brows: [CAShapeLayer] = []
    private var cheeks: [CAShapeLayer] = []
    private var mouth = CAShapeLayer()
    private let kettle = CALayer()
    private let pour = CALayer()
    private var sparkles: [CAShapeLayer] = []
    private let bubble = CALayer()
    private var bubbleShape = CAShapeLayer()
    private var bubbleText = CATextLayer()

    private var mood: Mood?
    private var moodStill = false
    private var steamShape: (count: Int, pace: Int, still: Bool)?
    private var playedRefill: Date?
    private var kettleShown = false
    private var bubbleShown: String?

    /// Called when the pointer enters or leaves the cup.
    public var onHover: ((Bool) -> Void)?

    public init() {
        super.init(space: CGSize(width: 1024, height: 1024))
        build()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { onHover?(true) }
    public override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: Showing a pulse

    /// `text` is shown in a bubble: above the cup as an alert when the network is down, under it otherwise.
    public func show(_ pulse: Pulse, text: String?, now: Date = Date()) {
        let refill = pulse.sinceRefill(now)
        let mood: Mood = switch pulse.state {
        case .loggingIn: .looksUp
        case .broken, .noInternet, .offline: .sad
        case .paused: .calm
        case .online where refill != nil: .delighted
        case .online where pulse.bars <= 1: .worried
        case .online where pulse.busy > 0.6: .busy
        case .online: .calm
        }
        if mood != self.mood || still != moodStill { setMood(mood) }

        let steamShape = (count: pulse.isUp ? max(1, pulse.bars) : 0, pace: Int(pulse.busy * 3), still: still)
        if self.steamShape.map({ $0 != steamShape }) ?? true { setSteam(count: steamShape.count, busy: Double(steamShape.pace) / 3) }
        self.steamShape = steamShape

        if let refilled = pulse.refilled, refill != nil, refilled != playedRefill, !still {
            playedRefill = refilled
            playRefill()
        } else if refill == nil || still {
            setKettle(pulse.state == .loggingIn)
            setLevel(pulse.state == .loggingIn ? 0.15 : pulse.sessionLeft ?? 1, seconds: 1)
        }

        let alert = !pulse.isUp && pulse.state != .loggingIn && pulse.state != .paused
        setBubble(text, alert: alert)
    }

    // MARK: Building

    private func build() {
        _ = outlined(ellipse(512, 790, 250, 20), fill: NSColor.black.withAlphaComponent(0.13), stroke: nil, in: root)
        cup.frame = root.bounds
        root.addSublayer(cup)
        steam.frame = root.bounds
        cup.addSublayer(steam)
        for _ in 0..<3 {
            let box = CALayer()
            box.allowsGroupOpacity = true
            box.opacity = 0
            steam.addSublayer(box)
            let outline = outlined(wave(radius: 64), stroke: Palette.ink.withAlphaComponent(0.85), width: 40 + Palette.line * 2, in: box)
            let color = outlined(wave(radius: 64), stroke: Palette.caramel, width: 40, in: box)
            wisps.append((box, outline, color))
        }

        _ = outlined(ellipse(512, 772, 262, 42), fill: Palette.cream, in: cup)
        let handle = CGMutablePath()
        handle.addArc(center: CGPoint(x: 736, y: 622), radius: 62, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        _ = outlined(handle, stroke: Palette.ink, width: 38 + Palette.line * 2, in: cup)
        _ = outlined(handle, stroke: Palette.cream, width: 38, in: cup)

        let body = CGMutablePath()
        body.move(to: CGPoint(x: 318, y: 522))
        body.addLine(to: CGPoint(x: 706, y: 522))
        body.addCurve(to: CGPoint(x: 512, y: 748), control1: CGPoint(x: 706, y: 662), control2: CGPoint(x: 638, y: 748))
        body.addCurve(to: CGPoint(x: 318, y: 522), control1: CGPoint(x: 386, y: 748), control2: CGPoint(x: 318, y: 662))
        body.closeSubpath()
        tint.frame = root.bounds
        tint.colors = [Palette.cream.cgColor, Palette.creamShade.cgColor]
        tint.startPoint = CGPoint(x: 0.5, y: 560 / 1024)
        tint.endPoint = CGPoint(x: 0.5, y: 748 / 1024)
        let mask = CAShapeLayer()
        mask.path = body
        tint.mask = mask
        cup.addSublayer(tint)
        _ = outlined(body, stroke: Palette.ink, in: cup)

        // Rim, the cup's inside wall, and the coffee, which sinks as the session runs out.
        _ = outlined(ellipse(512, 522, 194, 34), fill: Palette.cream, in: cup)
        let inside = ellipse(512, 522, 176, 25)
        _ = outlined(inside, fill: Palette.wall, stroke: nil, in: cup)
        let well = CALayer()
        well.frame = root.bounds
        let wellMask = CAShapeLayer()
        wellMask.path = inside
        well.mask = wellMask
        cup.addSublayer(well)
        coffee.frame = root.bounds
        well.addSublayer(coffee)
        _ = outlined(ellipse(512, 526, 176, 25), fill: Palette.coffee, stroke: nil, in: coffee)
        _ = outlined(ellipse(477, 522, 75, 8), fill: Palette.crema.withAlphaComponent(0.7), stroke: nil, in: coffee)

        for x in [404.0, 620.0] { cheeks.append(outlined(ellipse(x, 665, 32, 15), fill: Palette.blush, stroke: nil, in: cup)) }
        for x in [440.0, 584.0] {
            let eye = CALayer()
            eye.bounds = CGRect(x: 0, y: 0, width: 34, height: 46)
            eye.position = CGPoint(x: x, y: 616)
            cup.addSublayer(eye)
            _ = outlined(ellipse(17, 23, 17, 23), fill: Palette.ink, stroke: nil, in: eye)
            _ = outlined(ellipse(21, 14, 6, 6), fill: .white, stroke: nil, in: eye)
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.12, 1]
            blink.keyTimes = [0, 0.967, 0.983, 1]
            blink.duration = 4.3
            eye.loop(blink, key: "blink", offset: x == 440 ? 0 : 0.02)
            eyes.append(eye)

            let squint = CGMutablePath()
            squint.move(to: CGPoint(x: x - 22, y: 624))
            squint.addQuadCurve(to: CGPoint(x: x + 22, y: 624), control: CGPoint(x: x, y: 594))
            squints.append(outlined(squint, stroke: Palette.ink, width: 11, in: cup))

            let side: CGFloat = x < 512 ? -1 : 1
            let brow = CGMutablePath()
            brow.move(to: CGPoint(x: x - 18 * side, y: 568))
            brow.addLine(to: CGPoint(x: x + 18 * side, y: 580))
            brows.append(outlined(brow, stroke: Palette.ink, width: 9, in: cup))
        }
        mouth = outlined(CGMutablePath(), stroke: Palette.ink, width: 9, in: cup)

        buildKettle()

        for spot in [CGPoint(x: 270, y: 430), CGPoint(x: 780, y: 400), CGPoint(x: 700, y: 250), CGPoint(x: 330, y: 270)] {
            let sparkle = outlined(star(at: .zero, size: 34), fill: Palette.sparkle, stroke: nil, in: root)
            sparkle.position = spot
            sparkle.transform = CATransform3DMakeScale(0, 0, 1)
            sparkles.append(sparkle)
        }

        root.addSublayer(bubble)
        bubble.opacity = 0
        bubbleShape = outlined(CGMutablePath(), fill: Palette.cream, stroke: Palette.ink, width: Palette.line * 0.8, in: bubble)
        bubbleText = text("", size: 50, weight: .semibold, color: Palette.ink, in: bubble)
    }

    /// A little kettle with a face at the top right, and the coffee it pours.
    private func buildKettle() {
        pour.frame = root.bounds
        pour.opacity = 0
        pour.allowsGroupOpacity = true
        root.addSublayer(pour)

        let stream = CGMutablePath()
        stream.move(to: CGPoint(x: 600, y: 238))
        stream.addQuadCurve(to: CGPoint(x: 520, y: 540), control: CGPoint(x: 540, y: 250))
        let outline = outlined(stream, stroke: Palette.ink, width: 22 + Palette.line * 2, in: pour)
        let color = outlined(stream, stroke: Palette.coffee, width: 22, in: pour)
        let wobble = CAKeyframeAnimation(keyPath: "transform.translation.x")
        wobble.values = [0, 3, -2, 0]
        wobble.duration = 0.35
        outline.loop(wobble, key: "wobble")
        color.loop(wobble, key: "wobble")
        for index in 0..<3 {
            let drop = outlined(ellipse(0, 0, 8, 8), fill: Palette.coffee, stroke: nil, in: pour)
            let side: CGFloat = index == 1 ? -1 : 1
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 520 + side * 26, y: 540))
            path.addQuadCurve(to: CGPoint(x: 520 + side * 76, y: 540), control: CGPoint(x: 520 + side * 51, y: 460))
            let hop = CAKeyframeAnimation(keyPath: "position")
            hop.path = path
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [hop, fade]
            group.duration = 0.42
            drop.loop(group, key: "splash", offset: Double(index) * 0.14)
        }

        kettle.frame = root.bounds
        kettle.opacity = 0
        kettle.allowsGroupOpacity = true
        root.addSublayer(kettle)
        let pot = CALayer()
        pot.bounds = CGRect(x: -200, y: -200, width: 400, height: 400)
        pot.position = CGPoint(x: 740, y: 210)
        pot.setAffineTransform(CGAffineTransform(rotationAngle: -28 * .pi / 180))
        kettle.addSublayer(pot)
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: -70, y: 30))
        neck.addQuadCurve(to: CGPoint(x: -150, y: -20), control: CGPoint(x: -130, y: 30))
        _ = outlined(neck, stroke: Palette.ink, width: 26 + Palette.line * 2, in: pot)
        _ = outlined(neck, stroke: Palette.cream, width: 26, in: pot)
        let handle = CGMutablePath()
        handle.addArc(center: CGPoint(x: 78, y: 4), radius: 44, startAngle: -80 * .pi / 180, endAngle: 80 * .pi / 180, clockwise: false)
        _ = outlined(handle, stroke: Palette.ink, width: 18 + Palette.line * 2, in: pot)
        _ = outlined(handle, stroke: Palette.cream, width: 18, in: pot)
        _ = outlined(CGPath(roundedRect: CGRect(x: -88, y: -60, width: 176, height: 140), cornerWidth: 64, cornerHeight: 64, transform: nil), fill: Palette.cream, in: pot)
        _ = outlined(ellipse(0, -64, 52, 18), fill: Palette.caramel, in: pot)
        _ = outlined(ellipse(0, -90, 14, 14), fill: Palette.ink, stroke: nil, in: pot)
        for x in [-30.0, 30.0] {
            let eye = CGMutablePath()
            eye.move(to: CGPoint(x: x - 13, y: 6))
            eye.addQuadCurve(to: CGPoint(x: x + 13, y: 6), control: CGPoint(x: x, y: 20))
            _ = outlined(eye, stroke: Palette.ink, width: 8, in: pot)
            _ = outlined(ellipse(x + (x < 0 ? -8 : 8), 33, 20, 9), fill: Palette.blush, stroke: nil, in: pot)
        }
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: -10, y: 30))
        smile.addQuadCurve(to: CGPoint(x: 10, y: 30), control: CGPoint(x: 0, y: 42))
        _ = outlined(smile, stroke: Palette.ink, width: 7, in: pot)
    }

    // MARK: Changes

    private func setMood(_ mood: Mood) {
        self.mood = mood
        moodStill = still
        let happy = mood == .delighted || mood == .busy
        let unwell = mood == .worried || mood == .sad
        let lift: CGFloat = mood == .looksUp ? -12 : mood == .sad ? 8 : 0
        quietly {
            for (index, eye) in eyes.enumerated() {
                eye.isHidden = happy
                eye.position = CGPoint(x: index == 0 ? 440 : 584, y: 616 + lift)
            }
            squints.forEach { $0.isHidden = !happy }
            brows.forEach {
                $0.isHidden = !unwell
                $0.setAffineTransform(CGAffineTransform(translationX: 0, y: lift))
            }
            cheeks.forEach { $0.opacity = mood == .sad ? 0.4 : 1 }
            let y = 664 + lift
            let path = CGMutablePath()
            switch mood {
            case .sad:
                path.move(to: CGPoint(x: 490, y: y + 10))
                path.addQuadCurve(to: CGPoint(x: 534, y: y + 10), control: CGPoint(x: 512, y: y - 10))
            case .worried:
                path.move(to: CGPoint(x: 486, y: y))
                path.addCurve(to: CGPoint(x: 538, y: y), control1: CGPoint(x: 500, y: y - 14), control2: CGPoint(x: 524, y: y + 14))
            case .delighted, .busy, .looksUp:
                path.move(to: CGPoint(x: 488, y: y - 6))
                path.addQuadCurve(to: CGPoint(x: 536, y: y - 6), control: CGPoint(x: 512, y: y + 34))
                path.closeSubpath()
            case .calm:
                path.move(to: CGPoint(x: 492, y: y - 4))
                path.addQuadCurve(to: CGPoint(x: 532, y: y - 4), control: CGPoint(x: 512, y: y + 18))
            }
            mouth.path = path
            mouth.fillColor = happy || mood == .looksUp ? Palette.ink.cgColor : nil
        }
        // Cold and blue while the network is down.
        CATransaction.begin()
        CATransaction.setDisableActions(still)
        tint.colors = mood == .sad ? [Palette.chilly.cgColor, Palette.chillyShade.cgColor] : [Palette.cream.cgColor, Palette.creamShade.cgColor]
        CATransaction.commit()

        // A slow breath when calm, a bounce when busy, a shiver now and then when down.
        cup.removeAnimation(forKey: "move")
        guard !still else { return }
        let move = CAKeyframeAnimation()
        move.isAdditive = true
        switch mood {
        case .busy:
            move.keyPath = "position.y"
            move.values = [0, -14, 0]
            move.duration = 0.9
            move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        case .sad:
            move.keyPath = "position.x"
            move.values = [0, 3, -3, 3, -3, 0, 0]
            move.keyTimes = [0, 0.02, 0.04, 0.06, 0.08, 0.1, 1]
            move.duration = 3.2
        default:
            move.keyPath = "position.y"
            move.values = [0, -7, 0, 7, 0]
            move.duration = 3.4
            move.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        }
        cup.loop(move, key: "move")
    }

    /// Wi-Fi arcs leaving the coffee and fading as they rise, like the icon's waves.
    private func setSteam(count: Int, busy: Double) {
        let period = 3.8 - 2.6 * busy
        let begin = steam.convertTime(CACurrentMediaTime(), from: nil)
        for (index, wisp) in wisps.enumerated() {
            for layer in [wisp.box, wisp.outline, wisp.color] { layer.removeAllAnimations() }
            quietly { wisp.box.opacity = 0 }
            guard index < count else { continue }
            let phase = Double(index) / Double(count)
            if still {
                // Reduce Motion: the arcs stand spread up the steam, one per bar.
                quietly {
                    wisp.box.opacity = 1
                    wisp.box.position = CGPoint(x: 512, y: 420 - phase * 220)
                    wisp.outline.path = wave(radius: 64 + phase * 90)
                    wisp.color.path = wave(radius: 64 + phase * 90)
                }
                continue
            }
            quietly {
                wisp.outline.path = wave(radius: 64)
                wisp.color.path = wave(radius: 64)
            }
            let offset = phase * period
            let samples = (0...12).map { Double($0) / 12 }

            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = 440
            rise.toValue = 130
            let sway = CAKeyframeAnimation(keyPath: "position.x")
            sway.values = samples.map { 512 + sin($0 * 5.5 + Double(index) * 2.1) * 22 }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = samples.map { min(1, $0 * 6) * sin($0 * .pi) }
            let box = CAAnimationGroup()
            box.animations = [rise, sway, fade]
            box.duration = period

            for (layer, width) in [(wisp.outline, 40 + Palette.line * 2), (wisp.color, 40)] {
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = wave(radius: 64)
                grow.toValue = wave(radius: 184)
                let thin = CABasicAnimation(keyPath: "lineWidth")
                thin.fromValue = width
                thin.toValue = width - 18
                let group = CAAnimationGroup()
                group.animations = [grow, thin]
                group.duration = period
                group.repeatCount = .infinity
                group.beginTime = begin
                group.timeOffset = offset
                layer.add(group, forKey: "steam")
            }
            box.repeatCount = .infinity
            box.beginTime = begin
            box.timeOffset = offset
            wisp.box.add(box, forKey: "steam")
        }
    }

    private func setLevel(_ level: Double, seconds: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(still ? 0 : seconds)
        CATransaction.setDisableActions(still)
        coffee.position = CGPoint(x: 512, y: 512 + (1 - level) * 44)
        CATransaction.commit()
    }

    private func setKettle(_ shown: Bool) {
        guard shown != kettleShown else { return }
        kettleShown = shown
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setDisableActions(still)
        kettle.opacity = shown ? 1 : 0
        kettle.setAffineTransform(shown ? .identity : CGAffineTransform(translationX: 160, y: -160))
        pour.opacity = shown ? 1 : 0
        CATransaction.commit()
    }

    /// The kettle pours, the coffee rises, the kettle lifts away and the cup sparkles.
    private func playRefill() {
        setLevel(0.15, seconds: 0)
        setKettle(true)
        setLevel(1, seconds: 1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            self.pour.opacity = 0
            CATransaction.commit()
            self.setKettle(false)
        }
        let begin = root.convertTime(CACurrentMediaTime(), from: nil)
        for (index, sparkle) in sparkles.enumerated() {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0, 1, 0]
            pop.duration = 1.4
            pop.beginTime = begin + 0.8 + Double(index) * 0.25
            sparkle.add(pop, forKey: "pop")
        }
    }

    /// A speech bubble above the cup when something is wrong, or a caption under the saucer.
    private func setBubble(_ string: String?, alert: Bool) {
        let key = string.map { "\(alert)\($0)" }
        guard key != bubbleShown else { return }
        bubbleShown = key
        guard let string else {
            CATransaction.begin()
            CATransaction.setDisableActions(still)
            bubble.opacity = 0
            CATransaction.commit()
            return
        }
        quietly {
            set(bubbleText, string, size: 50, weight: .semibold, color: Palette.ink)
            let size = bubbleText.bounds.size
            let width = min(960, size.width + 70)
            let box = CGRect(x: 512 - width / 2, y: alert ? 120 : 846, width: width, height: size.height + 34)
            let path = CGMutablePath()
            path.addRoundedRect(in: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2)
            if alert {
                path.move(to: CGPoint(x: 492, y: box.maxY))
                path.addLine(to: CGPoint(x: 512, y: box.maxY + 34))
                path.addLine(to: CGPoint(x: 534, y: box.maxY))
            }
            bubbleShape.path = path
            bubbleText.position = CGPoint(x: box.midX, y: box.midY)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(still)
        bubble.opacity = 1
        CATransaction.commit()
    }
}
