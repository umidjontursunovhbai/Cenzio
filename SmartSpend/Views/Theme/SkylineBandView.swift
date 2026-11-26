import SwiftUI

/// Dashboard header band: a sharp skyline (night in dark mode, day in light mode). Every
/// lit window is a day of this month with at least one expense; today's window glows.
/// The taxi drives along the street once each time the band appears, or stays parked.
struct SkylineBandView: View {
    /// Days of the month (1-based) with at least one expense.
    let litDays: Set<Int>
    /// Today's day of the month.
    let today: Int
    /// Parked taxi (add expense sheet) instead of one drive across.
    var parkedTaxi = false
    /// Strength of the glow around today's window, 0...1. Animatable.
    var glow: Double = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var taxiX: CGFloat = -130

    /// Distance of the street line from the bottom of the band.
    static let street: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                SkylineBandCanvas(lit: litDays, today: today, day: colorScheme != .dark, glow: glow)
                if !typeSize.isAccessibilitySize {
                    // taxi wheels sit on the street line (its box reaches 1 unit below the wheels)
                    StreetFigureView(figure: .taxi, height: 24, walksIn: false)
                        .offset(x: taxiX, y: -(Self.street - 1))
                }
            }
            .onAppear { drive(width: geo.size.width) }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drive(width: CGFloat) {
        if parkedTaxi {
            taxiX = 18
            return
        }
        guard !reduceMotion else {
            taxiX = 120
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { taxiX = -130 }
        withAnimation(.timingCurve(0.45, 0.05, 0.4, 1, duration: 3.6).delay(0.5)) {
            taxiX = width + 20
        }
    }
}

/// The band drawing; `glow` animates so today's window can fade in on save.
private struct SkylineBandCanvas: View, Animatable {
    let lit: Set<Int>
    let today: Int
    let day: Bool
    var glow: Double

    var animatableData: Double {
        get { glow }
        set { glow = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            SkylineBand.draw(ctx, size: size, lit: lit, today: today, day: day, glow: glow)
        }
    }
}

/// Drawing for `SkylineBandView`, using the onboarding skyline (`City.base`) squeezed into the band.
enum SkylineBand {
    struct Window {
        let x: Double, y: Double
    }

    private static func rgb(_ c: [Double], _ a: Double = 1) -> Color {
        Color(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, opacity: max(0, min(1, a)))
    }

    /// All windows of the band towers (street at y = 0, design units), in a fixed shuffled
    /// order so day 1, 2, 3... light windows spread over the city.
    static func windows(heightScale k: Double) -> [Window] {
        var out: [(Double, Window)] = []
        for (ti, t) in City.base.enumerated() {
            let h = t.2 * k
            let cols = Int(floor((t.1 - 8) / 8)), rows = Int(floor((h - 30) / 10))
            guard cols > 0, rows > 0 else { continue }
            for c in 0..<cols {
                for r in 0..<rows {
                    let key: Double = City.hash(Double(ti), Double(c), Double(r))
                    let x: Double = t.0 + 5 + Double(c) * 8
                    let y: Double = -24 - Double(r) * 10
                    out.append((key, Window(x: x, y: y)))
                }
            }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func draw(_ base: GraphicsContext, size: CGSize, lit: Set<Int>, today: Int, day: Bool, glow: Double) {
        let s = size.width / City.W
        let streetY = size.height - SkylineBandView.street
        let sky = City.sky[day ? "day" : "night"]!

        // sky, faded in from the page at the top so the band has no hard upper edge
        base.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: streetY)), with: .linearGradient(
            Gradient(stops: [.init(color: rgb(sky[0], 0), location: 0), .init(color: rgb(sky[0], 0.9), location: 0.3),
                             .init(color: rgb(sky[1]), location: 0.75), .init(color: rgb(sky[2]), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: streetY)))
        if !day {
            var stars = Path()
            for (x, y, r, _) in City.stars where y * s < streetY * 0.55 && y * s > streetY * 0.2 {
                stars.addRect(CGRect(x: x * s, y: y * s, width: r, height: r))
            }
            base.fill(stars, with: .color(Color(red: 230 / 255, green: 236 / 255, blue: 1, opacity: 0.6)))
        }

        var ctx = base
        ctx.translateBy(x: 0, y: streetY)
        ctx.scaleBy(x: s, y: s)
        let k = min(1, (streetY / s - 10) / 256)
        let dawn = day ? 1.0 : 0
        let towerCol = rgb([7 + 23 * dawn, 10 + 27 * dawn, 20 + 32 * dawn])

        // ground below the street, fading into the page
        ctx.fill(Path(CGRect(x: 0, y: 0, width: City.W, height: SkylineBandView.street / s)), with: .linearGradient(
            Gradient(colors: [towerCol, towerCol.opacity(0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: SkylineBandView.street / s)))

        var bodies = Path()
        for t in City.base {
            bodies.addRect(CGRect(x: t.0, y: -t.2 * k, width: t.1, height: t.2 * k))
        }
        ctx.fill(bodies, with: .color(towerCol))

        let all = windows(heightScale: k)
        var dark = Path()
        for w in all { dark.addRect(CGRect(x: w.x, y: w.y, width: 4, height: 5)) }
        ctx.fill(dark, with: .color(rgb([30, 42, 74], 0.55 * (1 - dawn * 0.6))))

        let amber = [242.0, 169, 59]
        var on = Path()
        for d in lit where d >= 1 && d <= all.count {
            let w = all[d - 1]
            on.addRect(CGRect(x: w.x, y: w.y, width: 4, height: 5))
        }
        ctx.fill(on, with: .color(rgb(amber, 0.9)))
        if lit.contains(today), today >= 1, today <= all.count, glow > 0.01 {
            let w = all[today - 1]
            ctx.fill(Path(ellipseIn: CGRect(x: w.x - 12, y: w.y - 12, width: 28, height: 29)), with: .radialGradient(
                Gradient(colors: [rgb(amber, 0.55 * glow), rgb(amber, 0)]),
                center: CGPoint(x: w.x + 2, y: w.y + 2.5), startRadius: 1, endRadius: 14))
            ctx.fill(Path(CGRect(x: w.x - 1, y: w.y - 1, width: 6, height: 7)), with: .color(rgb([255, 214, 150], glow)))
        }

        // street line and lamps
        ctx.fill(Path(CGRect(x: 0, y: 0, width: City.W, height: 1 / s)), with: .color(rgb([201, 211, 224], 0.35 + dawn * 0.4)))
        let night = 1 - dawn
        for x in [44.0, 232] {
            let glow = NightTheme.window
            ctx.fill(Path(CGRect(x: x - 30, y: -64, width: 70, height: 64)), with: .radialGradient(
                Gradient(colors: [glow.opacity(0.5 * night), glow.opacity(0)]),
                center: CGPoint(x: x + 5, y: -30), startRadius: 1, endRadius: 34))
            ctx.fill(Path(CGRect(x: x, y: -30, width: 1.5, height: 30)), with: .color(NightTheme.ink))
            ctx.fill(Path(CGRect(x: x, y: -31, width: 7, height: 1.5)), with: .color(NightTheme.ink))
            ctx.fill(Path(CGRect(x: x + 5, y: -30, width: 3, height: 2)), with: .color(rgb([255, 214, 150], 0.3 + 0.7 * night)))
        }
    }
}
