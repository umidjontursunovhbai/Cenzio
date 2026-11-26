import SwiftUI

/// The small people, the street lamp and the taxi from the onboarding street.
/// One drawing code for the onboarding city (`NightCityView`) and for the figures
/// that stand on headings and buttons in the rest of the app (`StreetFigureView`).
/// Units: 1 = one design point; the feet (or wheels) touch y = 0.
enum StreetCast {
    struct Pose {
        var walk = false, ph = 0.0, dir = 1.0, alpha = 1.0, eat = false, bags = false
        /// Onboarding draws people 1.2x; figures in the app draw them 1x and scale the canvas.
        var scale = 1.2
    }

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
        Path(CGRect(x: x, y: y, width: w, height: h))
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    private static func line(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ w: Double, _ color: Color) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
    }

    static let bun = Color(red: 217 / 255, green: 154 / 255, blue: 74 / 255)
    static let bagLight = Color(red: 180 / 255, green: 138 / 255, blue: 90 / 255)
    static let bagDark = Color(red: 143 / 255, green: 108 / 255, blue: 69 / 255)

    /// A walking or standing person: legs, body, head, and arms (plain, eating a bun, or carrying bags).
    static func person(_ base: GraphicsContext, _ x: Double, _ y: Double, _ o: Pose, color: Color, reduce: Bool) {
        var ctx = base
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: o.dir < 0 ? -o.scale : o.scale, y: o.scale)
        ctx.opacity = max(0, o.alpha)
        let ph = reduce ? 0 : o.ph
        let sw = o.walk ? sin(ph) * 0.5 : 0
        for a in [sw, -sw] { line(ctx, CGPoint(x: 0, y: -10), CGPoint(x: sin(a) * 10, y: -10 + cos(a) * 10), 2.6, color) }
        line(ctx, CGPoint(x: 0, y: -11), CGPoint(x: 0, y: -18.5), 4.6, color)
        ctx.fill(circle(0.6, -22.4, 3), with: .color(color))
        if o.eat {
            let k = (sin(ph * 0.45) + 1) / 2
            let hx = 3.2 + k * 0.8, hy = -12 - k * 8
            line(ctx, CGPoint(x: 0.5, y: -17.5), CGPoint(x: hx, y: hy), 2, color)
            var b = ctx
            b.translateBy(x: hx + 1.6, y: hy - 0.5)
            b.rotate(by: .radians(-0.4))
            b.fill(Path(ellipseIn: CGRect(x: -2.4, y: -1.6, width: 4.8, height: 3.2)), with: .color(bun))
            line(ctx, CGPoint(x: 0, y: -17.5), CGPoint(x: -sin(sw) * 6, y: -11), 2, color)
        } else if o.bags {
            for (bx, c) in [(2.5, bagLight), (-2.0, bagDark)] {
                line(ctx, CGPoint(x: 0, y: -17.5), CGPoint(x: bx, y: -11), 2, color)
                ctx.fill(rect(bx - 3, -11, 6, 7), with: .color(c))
                var handle = Path()
                handle.addArc(center: CGPoint(x: bx, y: -11), radius: 1.8, startAngle: .radians(.pi), endAngle: .radians(0), clockwise: false)
                ctx.stroke(handle, with: .color(c), lineWidth: 1)
            }
        } else {
            for a in [-sw, sw] { line(ctx, CGPoint(x: 0, y: -17.5), CGPoint(x: sin(a) * 6, y: -11), 2, color) }
        }
    }

    /// The yellow taxi with its headlight beam, 46 long, facing right. `rims` outlines the
    /// wheels so they show on a dark ground outside the city.
    static func taxi(_ base: GraphicsContext, _ x: Double, _ y: Double, wheel: Color, rims: Bool = false) {
        var ctx = base
        ctx.translateBy(x: x, y: y)
        var beam = Path()
        beam.move(to: CGPoint(x: 44, y: -9)); beam.addLine(to: CGPoint(x: 110, y: -16))
        beam.addLine(to: CGPoint(x: 110, y: 0)); beam.addLine(to: CGPoint(x: 44, y: -5)); beam.closeSubpath()
        let beamColor = Color(red: 1, green: 220 / 255, blue: 150 / 255)
        ctx.fill(beam, with: .linearGradient(Gradient(colors: [beamColor.opacity(0.35), beamColor.opacity(0)]),
                                             startPoint: CGPoint(x: 44, y: 0), endPoint: CGPoint(x: 110, y: 0)))
        let yellow = NightTheme.taxi
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: -13, width: 46, height: 9), cornerRadius: 3), with: .color(yellow))
        var cabin = Path()
        cabin.move(to: CGPoint(x: 10, y: -13)); cabin.addLine(to: CGPoint(x: 15, y: -20))
        cabin.addLine(to: CGPoint(x: 31, y: -20)); cabin.addLine(to: CGPoint(x: 37, y: -13)); cabin.closeSubpath()
        ctx.fill(cabin, with: .color(yellow))
        let glass = Color(red: 26 / 255, green: 36 / 255, blue: 64 / 255)
        var w1 = Path()
        w1.move(to: CGPoint(x: 13, y: -13.5)); w1.addLine(to: CGPoint(x: 16.5, y: -18.5))
        w1.addLine(to: CGPoint(x: 22.5, y: -18.5)); w1.addLine(to: CGPoint(x: 22.5, y: -13.5)); w1.closeSubpath()
        var w2 = Path()
        w2.move(to: CGPoint(x: 24, y: -13.5)); w2.addLine(to: CGPoint(x: 24, y: -18.5))
        w2.addLine(to: CGPoint(x: 30, y: -18.5)); w2.addLine(to: CGPoint(x: 34, y: -13.5)); w2.closeSubpath()
        ctx.fill(w1, with: .color(glass)); ctx.fill(w2, with: .color(glass))
        ctx.fill(rect(19, -23, 9, 3), with: .color(Color(red: 1, green: 241 / 255, blue: 196 / 255)))
        ctx.fill(rect(43, -11, 3, 2.4), with: .color(Color(red: 1, green: 246 / 255, blue: 216 / 255)))
        ctx.fill(rect(0, -11, 2, 2.4), with: .color(Color(red: 1, green: 92 / 255, blue: 72 / 255)))
        for cx in [10.0, 36] {
            ctx.fill(circle(cx, -3.5, 3.6), with: .color(wheel))
            if rims {
                ctx.stroke(circle(cx, -3.5, 3.6), with: .color(Color(red: 58 / 255, green: 69 / 255, blue: 96 / 255)), lineWidth: 0.8)
            }
        }
    }

    /// A person on a bicycle, facing right. With a pedal phase `ph` the wheels show a
    /// turning spoke and the leg follows the pedal; without it the rider is drawn still.
    static func cyclist(_ ctx: GraphicsContext, color: Color, ph: Double? = nil) {
        for cx in [-7.0, 7] {
            ctx.stroke(circle(cx, -4.5, 4.3), with: .color(color), lineWidth: 1.4)
            if let ph {
                let dx = cos(ph) * 4, dy = sin(ph) * 4
                line(ctx, CGPoint(x: cx - dx, y: -4.5 - dy), CGPoint(x: cx + dx, y: -4.5 + dy), 0.7, color)
            }
        }
        let frame: [(Double, Double, Double, Double, Double)] = [
            (-7, -4.5, -1, -4.5, 1.4), (-1, -4.5, 4, -11, 1.4), (-1, -4.5, -3, -12, 1.4),
            (4, -11, 7, -4.5, 1.4), (-4.5, -12, -1.5, -12, 1.6),
            (-2, -12, 1, -19, 4.4), (0.5, -17.5, 5, -12, 2),
        ]
        for (x1, y1, x2, y2, w) in frame {
            line(ctx, CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), w, color)
        }
        if let ph {
            // foot on a pedal circling the crank (-1, -4.5); knee halfway, pushed forward
            let foot = CGPoint(x: -1 + cos(ph) * 2.6, y: -4.5 + sin(ph) * 2.6)
            let knee = CGPoint(x: (foot.x - 2) / 2 + 1.5, y: (foot.y - 12) / 2 - 1)
            line(ctx, CGPoint(x: -2, y: -12), knee, 2.4, color)
            line(ctx, knee, foot, 2.4, color)
        } else {
            line(ctx, CGPoint(x: -2, y: -12), CGPoint(x: 0, y: -6), 2.4, color)
            line(ctx, CGPoint(x: 0, y: -6), CGPoint(x: -1, y: -4.5), 2.4, color)
        }
        ctx.fill(circle(2.2, -22.6, 3), with: .color(color))
    }

    /// A street lamp with its warm glow, 34 tall.
    static func lamp(_ ctx: GraphicsContext, color: Color) {
        let warm = NightTheme.window
        ctx.fill(circle(5, -31, 14), with: .radialGradient(
            Gradient(colors: [warm.opacity(0.55), warm.opacity(0)]),
            center: CGPoint(x: 5, y: -31), startRadius: 0, endRadius: 14))
        line(ctx, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -34), 1.8, color)
        line(ctx, CGPoint(x: 0, y: -34), CGPoint(x: 5, y: -34), 1.6, color)
        ctx.fill(Path(roundedRect: CGRect(x: 2.5, y: -33, width: 5, height: 2.6), cornerRadius: 1),
                 with: .color(Color(red: 1, green: 214 / 255, blue: 150 / 255)))
    }
}

// MARK: - A single figure for headings and buttons

enum StreetFigure {
    case walker, shopper, snacker, cyclist, lamp, taxi

    /// Drawing bounds in design units (feet at y = 0).
    var box: CGRect {
        switch self {
        case .walker, .snacker: CGRect(x: -8, y: -27, width: 16, height: 27)
        case .shopper: CGRect(x: -9, y: -27, width: 18, height: 27)
        case .cyclist: CGRect(x: -13, y: -27, width: 26, height: 27)
        case .lamp: CGRect(x: -16, y: -42, width: 32, height: 42)
        case .taxi: CGRect(x: -2, y: -25, width: 114, height: 26)
        }
    }

    /// Props stand still; people walk in, the taxi rolls in.
    var walksIn: Bool { self != .lamp }
}

/// One street figure drawn with Canvas. Decoration only: no hit testing, hidden from
/// VoiceOver. On appear it walks in about 40 pt over 1.2 s and then stands at rest;
/// with Reduce Motion it is drawn at rest. Nothing loops.
struct StreetFigureView: View {
    let figure: StreetFigure
    /// Height of the drawing box in points (feet to the top of the head is about 94% of it).
    var height: CGFloat = 22
    var walksIn = true
    /// Faces left (the shopper turns after Save).
    var turned = false
    /// Overrides the default figure color (white in dark mode, ink in light mode).
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var start: Date?
    @State private var arrived = false

    static let walkTime = 1.2

    private var animates: Bool { walksIn && figure.walksIn && !reduceMotion }

    var body: some View {
        let box = figure.box
        let scale = height / box.height
        let ink = color ?? NightTheme.figure(colorScheme)
        TimelineView(.animation(paused: !animates || arrived || start == nil)) { tl in
            let t: Double = {
                guard animates, !arrived else { return Self.walkTime }
                guard let start else { return 0 }
                return min(Self.walkTime, tl.date.timeIntervalSince(start))
            }()
            let k = t / Self.walkTime
            let eased = 1 - pow(1 - k, 3)
            Canvas { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                draw(ctx, color: ink, walking: k < 1, ph: t * 9)
            }
            .offset(x: -40 * (1 - eased))
            .opacity(animates && !arrived ? min(1, t / 0.3) : 1)
        }
        .frame(width: box.width * scale, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard animates, start == nil else { return }
            start = .now
            try? await Task.sleep(for: .seconds(Self.walkTime + 0.05))
            arrived = true
        }
    }

    private func draw(_ ctx: GraphicsContext, color: Color, walking: Bool, ph: Double) {
        let dir: Double = turned ? -1 : 1
        switch figure {
        case .walker:
            StreetCast.person(ctx, 0, 0, .init(walk: walking, ph: ph, dir: dir, scale: 1), color: color, reduce: false)
        case .shopper:
            StreetCast.person(ctx, 0, 0, .init(walk: walking, ph: ph, dir: dir, bags: true, scale: 1), color: color, reduce: false)
        case .snacker:
            // the bun stays at the mouth level once at rest
            StreetCast.person(ctx, 0, 0, .init(walk: walking, ph: walking ? ph : 3.5, dir: dir, eat: true, scale: 1), color: color, reduce: false)
        case .cyclist:
            StreetCast.cyclist(ctx, color: color)
        case .lamp:
            StreetCast.lamp(ctx, color: color)
        case .taxi:
            StreetCast.taxi(ctx, 0, 0, wheel: NightTheme.ink, rims: true)
        }
    }
}

// MARK: - Figures that keep moving (Settings)

extension EnvironmentValues {
    /// True while the screen scrolls: looping figures hold still so scrolling stays smooth.
    @Entry var streetMotionPaused = false
}

/// Accumulates only the time the loop actually ran, so a figure resumes where it
/// stopped after a scroll or a trip to the background instead of jumping ahead.
private final class StreetClock {
    var t: Double = 0
    var last: Date?

    func tick(_ now: Date) -> Double {
        if let last { t += min(max(0, now.timeIntervalSince(last)), 1.0 / 12) }
        last = now
        return t
    }
}

/// A street figure that keeps moving in a lane as wide as its frame: the cyclist rides
/// across and comes back in from the left, the snacker eats in place, people pace back
/// and forth. 24 frames a second, and it holds still while scrolling, when off screen,
/// in the background, in Low Power Mode and with Reduce Motion. Decoration only.
struct StreetLoopView: View {
    let figure: StreetFigure
    var height: CGFloat = 22
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.streetMotionPaused) private var scrolling
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var clock = StreetClock()

    private var still: Bool { reduceMotion || lowPower }
    private var paused: Bool { still || scrolling || !visible || scenePhase != .active }

    var body: some View {
        let box = figure.box
        let scale = height / box.height
        let ink = color ?? NightTheme.figure(colorScheme)
        GeometryReader { geo in
            let lane = geo.size.width
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { tl in
                let t = paused ? clock.t : clock.tick(tl.date)
                Canvas { ctx, _ in
                    var c = ctx
                    let w = box.width * scale
                    let (x, dir) = position(t: t, lane: lane, width: w)
                    c.translateBy(x: x, y: 0)
                    c.scaleBy(x: scale, y: scale)
                    c.translateBy(x: -box.minX, y: -box.minY)
                    draw(c, color: ink, t: t, dir: dir)
                }
            }
            .onChange(of: paused) { _, isPaused in if isPaused { clock.last = nil } }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Left edge of the drawing in the lane, and the facing direction.
    private func position(t: Double, lane: CGFloat, width: CGFloat) -> (CGFloat, Double) {
        let room = max(0, lane - width)
        switch figure {
        case .cyclist, .taxi:
            if still { return (room, 1) }
            let span = lane + width
            return (CGFloat((t * 26).truncatingRemainder(dividingBy: span)) - width, 1)
        case .walker, .shopper:
            guard !still, room > 4 else { return (room, 1) }
            let period = 2 * room / 18
            let u = t.truncatingRemainder(dividingBy: period) / period
            return u < 0.5 ? (room * u * 2, 1) : (room * (1 - (u - 0.5) * 2), -1)
        case .snacker, .lamp:
            return (0, 1)
        }
    }

    private func draw(_ ctx: GraphicsContext, color: Color, t: Double, dir: Double) {
        switch figure {
        case .walker:
            StreetCast.person(ctx, 0, 0, .init(walk: !still, ph: t * 7, dir: dir, scale: 1), color: color, reduce: still)
        case .shopper:
            StreetCast.person(ctx, 0, 0, .init(walk: !still, ph: t * 6.5, dir: dir, bags: true, scale: 1), color: color, reduce: still)
        case .snacker:
            StreetCast.person(ctx, 0, 0, .init(ph: still ? 3.5 : t * 4, eat: true, scale: 1), color: color, reduce: false)
        case .cyclist:
            StreetCast.cyclist(ctx, color: color, ph: still ? nil : t * 6)
        case .lamp:
            StreetCast.lamp(ctx, color: color)
        case .taxi:
            StreetCast.taxi(ctx, 0, 0, wheel: NightTheme.ink, rims: true)
        }
    }
}
