import AppKit
import QuartzCore
import RefillCore

/// The way from this Mac to the internet as a little caramel card: four stops with faces, and coffee beans carrying
/// the traffic between them. More traffic, more beans; a weak signal or a slow router, slower beans. When a leg breaks
/// the beans pile up in front of it and that stop looks unwell, so the picture says where the problem is.
@MainActor
public final class BeanScene: Stage {
    static let stops: [CGFloat] = [100, 300, 500, 700]
    static let lane: CGFloat = 150

    /// Round corners for the card on its own; square where a window frames it.
    public var rounded = true { didSet { card.cornerRadius = rounded ? 56 : 0 } }
    private let card = CAGradientLayer()
    private var tracks: [CAShapeLayer] = []
    private let tunnel = CALayer()
    private let beans = CALayer()
    private var pool: [CALayer] = []
    private var stations: [(disc: CAShapeLayer, icon: CALayer, eyes: CALayer, crosses: CAShapeLayer, sweat: CALayer, label: CATextLayer)] = []
    private var latency = CATextLayer()
    private var caption = CATextLayer()
    private var sparkles: [CAShapeLayer] = []

    private var flow: Flow?
    private var shownCaption: String?
    private var playedRefill: Date?

    /// What the beans do; they are only re-timed when it changes.
    struct Flow: Equatable {
        var blocked: Int?
        var count: Int
        var legs: [Double]
        var still: Bool
    }

    public init() {
        super.init(space: CGSize(width: 800, height: 340))
        build()
    }

    /// `text` is the line under the stops: what is going on, in the menu's words.
    public func show(_ pulse: Pulse, text: String, now: Date = Date()) {
        let blocked: Int? = switch pulse.state {
        case .online, .paused: nil
        case .offline: 1
        case .noInternet: 3
        case .loggingIn: 2
        case .broken(let leg):
            switch leg {
            case .wifi: 1
            case .router, .loginPage: 2
            case .dns, .internet, .vpn: 3
            }
        }
        quietly {
            for (index, track) in tracks.enumerated() {
                track.opacity = blocked.map { index == $0 - 1 } ?? false ? 0.25 : 0.55
            }
            // The radio leg's dashes thin out as the signal weakens.
            tracks[0].lineDashPattern = [1, NSNumber(value: pulse.bars >= 3 ? 12 : pulse.bars == 2 ? 20 : 34)]
            tunnel.isHidden = !pulse.vpn
            for (index, station) in stations.enumerated() {
                // While Wi-Fi Refill logs in, the beans wait at the router, which is fine.
                let unwell = blocked == index && pulse.state != .loggingIn
                let unreached = blocked.map { index > $0 } ?? false
                station.disc.fillColor = (unwell ? Palette.chilly : Palette.cream.withAlphaComponent(unreached ? 0.6 : 1)).cgColor
                station.icon.opacity = unwell || unreached ? 0.45 : 1
                station.eyes.isHidden = unwell
                station.crosses.isHidden = !unwell
                station.sweat.isHidden = !unwell
                station.label.opacity = unreached ? 0.5 : 1
            }
            if let ms = pulse.routerMilliseconds, pulse.isUp {
                set(latency, "\(ms) ms", size: 19, weight: .medium, color: Palette.cream.withAlphaComponent(0.85))
                latency.position = CGPoint(x: 400, y: Self.lane - 42)
                latency.isHidden = false
            } else {
                latency.isHidden = true
            }
            if shownCaption != text {
                shownCaption = text
                set(caption, text, size: 26, weight: .bold, color: Palette.cream)
                caption.position = CGPoint(x: 400, y: 300)
            }
        }

        let ms = Double(pulse.routerMilliseconds ?? 5)
        let flow = Flow(blocked: blocked, count: pulse.state == .offline || pulse.state == .paused ? 0 : (blocked == nil ? 2 : 6) + Int(pulse.busy * 6),
                        legs: [0.7 + Double(3 - max(1, pulse.bars)) * 0.6, 0.5 + min(2, (ms / 10).rounded() / 4), 1.0], still: still)
        if flow != self.flow {
            self.flow = flow
            setBeans(flow)
        }

        if let refilled = pulse.refilled, pulse.sinceRefill(now) != nil, refilled != playedRefill {
            playedRefill = refilled
            let begin = root.convertTime(CACurrentMediaTime(), from: nil)
            for (index, sparkle) in sparkles.enumerated() {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0, 1, 0]
                pop.duration = 1.2
                pop.beginTime = begin + Double(index) * 0.2
                sparkle.add(pop, forKey: "pop")
            }
        }
    }

    private func build() {
        card.frame = root.bounds
        card.colors = [Palette.caramel.cgColor, Palette.caramelDeep.cgColor]
        card.startPoint = .zero
        card.endPoint = CGPoint(x: 1, y: 1)
        card.cornerRadius = 56
        root.addSublayer(card)

        for index in 0..<3 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: Self.stops[index] + 60, y: Self.lane))
            path.addLine(to: CGPoint(x: Self.stops[index + 1] - 60, y: Self.lane))
            tracks.append(outlined(path, stroke: Palette.cream, width: 8, in: root))
        }

        tunnel.frame = root.bounds
        root.addSublayer(tunnel)
        let tube = outlined(CGPath(roundedRect: CGRect(x: 552, y: Self.lane - 30, width: 96, height: 60), cornerWidth: 30, cornerHeight: 30, transform: nil),
                         fill: Palette.cream.withAlphaComponent(0.18), stroke: Palette.cream.withAlphaComponent(0.6), width: 4, in: tunnel)
        tube.lineDashPattern = [10, 8]
        let lock = CALayer()
        lock.contents = symbol("lock.fill", size: 22, color: Palette.cream)
        lock.contentsGravity = .resizeAspect
        lock.frame = CGRect(x: 588, y: Self.lane - 66, width: 24, height: 30)
        tunnel.addSublayer(lock)

        beans.frame = root.bounds
        root.addSublayer(beans)
        for _ in 0..<12 {
            let bean = CALayer()
            bean.bounds = CGRect(x: -15, y: -10, width: 30, height: 20)
            bean.isHidden = true
            beans.addSublayer(bean)
            _ = outlined(ellipse(0, 0, 15, 10), fill: Palette.coffee, stroke: Palette.ink, width: 3, in: bean)
            let crease = CGMutablePath()
            crease.move(to: CGPoint(x: -11, y: 1))
            crease.addCurve(to: CGPoint(x: 11, y: -1), control1: CGPoint(x: -4, y: -6), control2: CGPoint(x: 4, y: 6))
            _ = outlined(crease, stroke: Palette.crema, width: 3, in: bean)
            pool.append(bean)
        }

        let names = [L("Mac"), L("Wi-Fi"), L("Router"), L("Internet")]
        let symbols = ["laptopcomputer", "wifi", "wifi.router", "globe.asia.australia.fill"]
        for index in 0..<4 {
            let x = Self.stops[index], y = Self.lane
            let disc = outlined(ellipse(x, y, 56, 56), fill: Palette.cream, stroke: Palette.ink, width: 6, in: root)
            let icon = CALayer()
            icon.contents = symbol(symbols[index], size: 40, color: Palette.ink)
            icon.contentsGravity = .resizeAspect
            icon.frame = CGRect(x: x - 26, y: y - 42, width: 52, height: 42)
            root.addSublayer(icon)

            let eyes = CALayer()
            eyes.bounds = CGRect(x: -20, y: -7, width: 40, height: 14)
            eyes.position = CGPoint(x: x, y: y + 24)
            root.addSublayer(eyes)
            _ = outlined(ellipse(-15, 0, 5, 7), fill: Palette.ink, stroke: nil, in: eyes)
            _ = outlined(ellipse(15, 0, 5, 7), fill: Palette.ink, stroke: nil, in: eyes)
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.15, 1]
            blink.keyTimes = [0, 0.97, 0.985, 1]
            blink.duration = 4.7
            eyes.loop(blink, key: "blink", offset: Double(index) * 1.3)

            let cross = CGMutablePath()
            for ex in [x - 15, x + 15] {
                cross.move(to: CGPoint(x: ex - 6, y: y + 18))
                cross.addLine(to: CGPoint(x: ex + 6, y: y + 30))
                cross.move(to: CGPoint(x: ex + 6, y: y + 18))
                cross.addLine(to: CGPoint(x: ex - 6, y: y + 30))
            }
            let crosses = outlined(cross, stroke: Palette.ink, width: 4, in: root)

            let sweat = CALayer()
            sweat.frame = root.bounds
            root.addSublayer(sweat)
            let drop = CGMutablePath()
            drop.move(to: CGPoint(x: x + 44, y: y - 50))
            drop.addQuadCurve(to: CGPoint(x: x + 44, y: y - 22), control: CGPoint(x: x + 30, y: y - 28))
            drop.addQuadCurve(to: CGPoint(x: x + 44, y: y - 50), control: CGPoint(x: x + 58, y: y - 28))
            _ = outlined(drop, fill: Palette.sweat, stroke: Palette.ink, width: 3, in: sweat)
            let slide = CAKeyframeAnimation(keyPath: "transform.translation.y")
            slide.values = [0, 0, 8, 0]
            slide.keyTimes = [0, 0.6, 0.9, 1]
            slide.duration = 1.6
            sweat.loop(slide, key: "slide")

            let label = text(names[index], size: 24, weight: .semibold, color: Palette.cream, in: root)
            label.position = CGPoint(x: x, y: y + 84)
            stations.append((disc, icon, eyes, crosses, sweat, label))
        }

        latency = text("", size: 19, weight: .medium, color: Palette.cream, in: root)
        caption = text("", size: 26, weight: .bold, color: Palette.cream, in: root)

        for spot in [CGPoint(x: 450, y: 70), CGPoint(x: 560, y: 60), CGPoint(x: 520, y: 30)] {
            let sparkle = outlined(star(at: .zero, size: 16), fill: Palette.sparkle, stroke: nil, in: root)
            sparkle.position = spot
            sparkle.transform = CATransform3DMakeScale(0, 0, 1)
            sparkles.append(sparkle)
        }
    }

    /// Beans out to the internet on the upper lane and back on the lower one, timed by each leg; or, when a leg is
    /// broken, a heap in front of it, hopping now and then.
    private func setBeans(_ flow: Flow) {
        let begin = beans.convertTime(CACurrentMediaTime(), from: nil)
        let stops = Self.stops
        let trip = flow.legs.reduce(0, +)
        var times: [NSNumber] = [0]
        for leg in flow.legs { times.append(NSNumber(value: (times.last!.doubleValue * trip + leg) / trip)) }

        for (index, bean) in pool.enumerated() {
            bean.removeAllAnimations()
            let inbound = flow.blocked == nil && index % 2 == 1
            let rank = flow.blocked == nil ? index / 2 : index
            quietly { bean.isHidden = index >= flow.count * (flow.blocked == nil ? 2 : 1) }
            guard !bean.isHidden else { continue }

            if let blocked = flow.blocked {
                let wall = stops[blocked] - 74
                quietly {
                    bean.position = CGPoint(x: wall - CGFloat(index % 4) * 20, y: Self.lane - 8 - CGFloat(index / 4) * 14)
                    bean.setAffineTransform(CGAffineTransform(rotationAngle: sin(Double(index)) * 0.5))
                }
                if flow.still { continue }
                let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
                hop.values = [0, -12, 0, 0]
                hop.keyTimes = [0, 0.12, 0.24, 1]
                hop.duration = 1.6 + Double(index % 3) * 0.3
                bean.loop(hop, key: "hop", offset: Double(index) * 0.37)
                continue
            }

            let spread = Double(rank) / Double(flow.count) + (inbound ? 0.5 / Double(flow.count) : 0)
            quietly {
                // Reduce Motion: the beans stand spread along the way.
                bean.position = CGPoint(x: flow.still ? stops[0] + (stops[3] - stops[0]) * spread : stops[0], y: Self.lane + (inbound ? 14 : -12))
                bean.setAffineTransform(inbound ? CGAffineTransform(rotationAngle: .pi) : .identity)
            }
            if flow.still { continue }
            let travel = CAKeyframeAnimation(keyPath: "position.x")
            travel.values = inbound ? stops.reversed() : stops
            travel.keyTimes = inbound ? times.reversed().map { NSNumber(value: 1 - $0.doubleValue) } : times
            travel.duration = trip
            travel.repeatCount = .infinity
            travel.beginTime = begin
            travel.timeOffset = Double(rank) / Double(flow.count) * trip + (inbound ? trip / 2 : 0)
            bean.add(travel, forKey: "travel")
        }
    }
}
