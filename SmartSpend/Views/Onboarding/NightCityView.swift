import SwiftUI

/// Onboarding pages. The same night city shows on every page; its sky, weather and street
/// scene change per page.
enum CityPage: String, CaseIterable {
    case welcome, add, voice, smart, budget, privacy
}

/// The onboarding skyline: every expense is a lit window. Drawn in a 390 x 500 design space
/// (the mockup's size) and scaled to the given frame. All motion is a pure function of time
/// since the last page change, so the view keeps no per-frame state.
struct NightCityView: View {
    let page: CityPage
    var reduceMotion = false
    /// Onboarding tags and labels over the city. Settings shows the bare city.
    var showsOverlay = true

    @State private var change = CityChange.initial

    var body: some View {
        GeometryReader { proxy in
            let sx = proxy.size.width / City.W
            let sy = proxy.size.height / City.H
            TimelineView(.animation(paused: reduceMotion)) { context in
                let frame = CityFrame(change: change, now: reduceMotion ? change.start : context.date, reduce: reduceMotion)
                ZStack(alignment: .topLeading) {
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        frame.draw(in: ctx, sx: sx, sy: sy)
                    }
                    if showsOverlay {
                        CityOverlay(frame: frame, sx: sx, sy: sy)
                    }
                }
            }
        }
        .onAppear {
            change = CityChange.first(page: page, reduce: reduceMotion)
        }
        .onChange(of: page) { _, newPage in
            change = change.next(to: newPage, at: .now, reduce: reduceMotion)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Model

/// Fixed numbers from the mockup (`outputs/onboarding-v3.html`).
enum City {
    static let W: Double = 390, H: Double = 500, HY: Double = 380
    /// Base skyline: x, width, height.
    static let base: [(Double, Double, Double)] = [
        (0, 34, 110), (30, 44, 170), (70, 30, 135), (96, 52, 220), (144, 36, 150), (176, 58, 256),
        (230, 34, 180), (260, 48, 212), (304, 30, 140), (330, 40, 186), (366, 30, 116),
    ]
    /// Week page: the towers that turn into Mon..Sun bars, and the bar heights.
    static let weekTowers = [1, 3, 4, 5, 6, 7, 9]
    static let weekHeights: [Double] = [112, 72, 144, 96, 212, 168, 56]
    static let limit: Double = 160
    /// Windows used by tags: tower, column, row.
    static let taxi = Win(t: 5, c: 3, r: 14), coffee = Win(t: 3, c: 2, r: 9), lunch = Win(t: 7, c: 2, r: 11)

    static let sky: [String: [[Double]]] = [
        "night": [[5, 9, 22], [13, 26, 62], [34, 58, 118]],
        "dusk": [[16, 26, 70], [96, 72, 130], [244, 146, 96]],
        "storm": [[8, 12, 24], [22, 32, 58], [50, 64, 98]],
        "day": [[78, 130, 200], [150, 185, 222], [250, 214, 170]],
    ]

    static func hash(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let s = sin(a * 127.1 + b * 311.7 + c * 74.7) * 43758.5453
        return s - floor(s)
    }

    static let stars: [(Double, Double, Double, Double)] = (0..<90).map { i in
        let i = Double(i)
        return (hash(i, 1, 2) * W, 30 + hash(i, 3, 4) * (HY - 170), 0.6 + hash(i, 5, 6) * 1.1, hash(i, 7, 8) * 6)
    }
    static let clouds: [(Double, Double, Double)] = (0..<5).map { i in
        let i = Double(i)
        return (hash(i, 9, 1) * (W + 160), 70 + hash(i, 2, 9) * 110, 30 + hash(i, 4, 2) * 40)
    }
    static let drops: [(Double, Double)] = (0..<150).map { i in (hash(Double(i), 6, 3), hash(Double(i), 8, 5)) }

    static func winXY(_ t: Tower, _ c: Int, _ r: Int) -> CGPoint {
        CGPoint(x: t.x + 5 + Double(c) * 8, y: HY - 34 - Double(r) * 10)
    }
}

struct Win: Hashable { let t: Int, c: Int, r: Int }

struct Tower {
    var x, w, h, lit: Double
}

struct Env {
    var stars = 0.0, rain = 0.0, clouds = 0.0, sun = 0.0, moon = 0.0
}

/// Everything about the city that eases between pages.
struct CityState {
    var towers: [Tower]
    var sky: [[Double]]
    var week: Double
    var dawn: Double
    var env: Env

    static func target(_ page: CityPage) -> CityState {
        let p = PageSpec.of(page)
        var towers = City.base.map { Tower(x: $0.0, w: $0.1, h: $0.2, lit: p.lit) }
        if p.week {
            for i in towers.indices where !City.weekTowers.contains(i) { towers[i].h = 0 }
            for (d, ti) in City.weekTowers.enumerated() {
                towers[ti] = Tower(x: 18 + Double(d) * 52, w: 42, h: City.weekHeights[d], lit: 0.95)
            }
        }
        return CityState(towers: towers, sky: City.sky[p.sky]!, week: p.week ? 1 : 0, dawn: p.day, env: p.env)
    }

    static func mix(_ a: CityState, _ b: CityState, _ k: Double) -> CityState {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        var out = b
        out.towers = zip(a.towers, b.towers).map { Tower(x: m($0.x, $1.x), w: m($0.w, $1.w), h: m($0.h, $1.h), lit: m($0.lit, $1.lit)) }
        out.sky = zip(a.sky, b.sky).map { zip($0, $1).map { m($0, $1) } }
        out.week = m(a.week, b.week)
        out.dawn = m(a.dawn, b.dawn)
        out.env = Env(stars: m(a.env.stars, b.env.stars), rain: m(a.env.rain, b.env.rain), clouds: m(a.env.clouds, b.env.clouds),
                      sun: m(a.env.sun, b.env.sun), moon: m(a.env.moon, b.env.moon))
        return out
    }
}

/// Per-page look and timings.
struct PageSpec {
    var sky: String
    var lit: Double
    var env: Env
    var week = false
    var day = 0.0

    static func of(_ page: CityPage) -> PageSpec {
        switch page {
        case .welcome: return PageSpec(sky: "dusk", lit: 0.5, env: Env(stars: 0.35, clouds: 0.45, sun: 0.14))
        case .add: return PageSpec(sky: "night", lit: 0.42, env: Env(stars: 1, moon: 1))
        case .voice: return PageSpec(sky: "storm", lit: 0.38, env: Env(rain: 1, clouds: 0.8))
        case .smart: return PageSpec(sky: "night", lit: 0.48, env: Env(stars: 1, moon: 1))
        case .budget: return PageSpec(sky: "night", lit: 0.92, env: Env(stars: 0.6, clouds: 0.4), week: true)
        case .privacy: return PageSpec(sky: "day", lit: 0, env: Env(clouds: 0.35, sun: 0.62), day: 1)
        }
    }

    /// Windows that light up with a glow on a page, and when (seconds after the page shows).
    static func glows(_ page: CityPage) -> [(Win, Double)] {
        switch page {
        case .add: return [(City.taxi, 0.7)]
        case .voice: return zip([City.coffee, City.taxi, City.lunch], VoiceScript.current.lightTimes).map { ($0, $1) }
        case .privacy: return [(City.taxi, 0)]
        default: return []
        }
    }
}

/// The typed voice line and the moments its three parts finish.
struct VoiceScript {
    let text: String
    /// Character counts after which each of the three parts is complete.
    let ends: [Int]

    static let charTime = 0.045, startDelay = 0.5, partPause = 0.35

    static var current: VoiceScript {
        let text = "onboarding_voice_line".localized
        let words = ["onboarding_tag_coffee", "onboarding_tag_taxi", "onboarding_tag_lunch"].map { $0.localized.lowercased() }
        let lower = text.lowercased()
        var ends: [Int] = []
        var from = lower.startIndex
        for word in words {
            if let range = lower.range(of: word, range: from..<lower.endIndex) {
                ends.append(lower.distance(from: lower.startIndex, to: range.upperBound))
                from = range.upperBound
            }
        }
        if ends.count != 3 {
            let n = text.count
            ends = [n / 3, 2 * n / 3, n]
        }
        ends[2] = text.count
        return VoiceScript(text: text, ends: ends)
    }

    /// Seconds after page start when part i is done (window lights 0.08 s later).
    func doneTime(_ i: Int) -> Double {
        Self.startDelay + Double(ends[i]) * Self.charTime + Double(i) * Self.partPause
    }

    var lightTimes: [Double] { (0..<3).map { doneTime($0) + 0.08 } }

    /// Characters shown at time t.
    func typed(at t: Double) -> Int {
        var shown = 0
        var start = Self.startDelay
        var prev = 0
        for i in 0..<3 {
            let len = ends[i] - prev
            let k = Int(max(0, (t - start) / Self.charTime))
            shown = prev + min(len, k)
            if k < len { return shown }
            start += Double(len) * Self.charTime + Self.partPause
            prev = ends[i]
        }
        return shown
    }
}

/// One page change: the state it started from and when.
struct CityChange {
    var from: CityState
    var to: CityState
    var page: CityPage
    var start: Date
    var duration: Double
    /// The page before, so its glowing windows can fade out.
    var prevPage: CityPage?
    var prevElapsed: Double

    static let initial = CityChange(from: .target(.welcome), to: .target(.welcome), page: .welcome, start: .now, duration: 0,
                                    prevPage: nil, prevElapsed: 0)

    static func first(page: CityPage, reduce: Bool) -> CityChange {
        var from = CityState.target(page)
        if page == .welcome && !reduce { for i in from.towers.indices { from.towers[i].lit = 0 } }
        return CityChange(from: from, to: .target(page), page: page, start: .now, duration: reduce ? 0 : 1.1, prevPage: nil, prevElapsed: 0)
    }

    func state(at now: Date) -> CityState {
        guard duration > 0 else { return to }
        let x = min(1, max(0, now.timeIntervalSince(start) / duration))
        return CityState.mix(from, to, 1 - pow(1 - x, 3))
    }

    func next(to page: CityPage, at now: Date, reduce: Bool) -> CityChange {
        var from = state(at: now)
        if page == .welcome && !reduce { for i in from.towers.indices { from.towers[i].lit = 0 } }
        return CityChange(from: from, to: .target(page), page: page, start: now, duration: reduce ? 0 : 1.1,
                          prevPage: self.page, prevElapsed: now.timeIntervalSince(start))
    }
}

/// One rendered moment: the eased city plus the page clock.
struct CityFrame {
    let s: CityState
    let page: CityPage
    /// Seconds since the page showed. Very large with Reduce Motion, so every reveal is done.
    let t: Double
    /// Clock for looping motion (stars, clouds, ripples). Zero with Reduce Motion.
    let m: Double
    let reduce: Bool
    let glow: [Win: Double]
    /// Walking person the floating tag follows (design space), if any.
    let walker: CGPoint?

    init(change: CityChange, now: Date, reduce: Bool) {
        self.reduce = reduce
        page = change.page
        s = change.state(at: now)
        t = reduce ? 1000 : max(0, now.timeIntervalSince(change.start))
        m = reduce ? 0 : now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)

        var glow: [Win: Double] = [:]
        func ramp(_ dt: Double) -> Double { dt <= 0 ? 0 : (reduce ? 1 : 1 - exp(-5 * dt)) }
        if let prev = change.prevPage, !reduce {
            let fade = exp(-5 * t)
            for (w, at) in PageSpec.glows(prev) { glow[w] = ramp(change.prevElapsed - at) * fade }
        }
        for (w, at) in PageSpec.glows(change.page) { glow[w] = max(glow[w] ?? 0, ramp(t - at)) }
        self.glow = glow

        // the floating tag follows a person in the street
        let sceneT = reduce ? 0 : t
        switch s.week <= 0.5 ? change.page : nil {
        case .welcome?:
            let tw = s.towers[5]
            walker = tw.h >= 150 ? CGPoint(x: tw.x + tw.w / 2 - 6 + 92, y: City.HY - 12) : nil
        case .smart?:
            let x = City.W + 30 - (110 + sceneT * 22).truncatingRemainder(dividingBy: City.W + 60)
            walker = CGPoint(x: x, y: City.HY - 34)
        default:
            walker = nil
        }
    }
}

// MARK: - Drawing

private let ink = Color(red: 2 / 255, green: 4 / 255, blue: 9 / 255)

private func rgb(_ c: [Double], _ a: Double = 1) -> Color {
    Color(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, opacity: max(0, min(1, a)))
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
    Path(CGRect(x: x, y: y, width: w, height: h))
}

private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

private func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> CGRect {
    CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)
}

extension CityFrame {
    var night: Double { 1 - s.dawn }

    func draw(in base: GraphicsContext, sx: Double, sy: Double) {
        var ctx = base
        ctx.scaleBy(x: sx, y: sy)
        let W = City.W, H = City.H, HY = City.HY

        // sky
        ctx.fill(rect(0, 0, W, HY), with: .linearGradient(
            Gradient(stops: [.init(color: rgb(s.sky[0]), location: 0), .init(color: rgb(s.sky[1]), location: 0.62),
                             .init(color: rgb(s.sky[2]), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: HY)))
        skyFx(&ctx)

        // water
        ctx.fill(rect(0, HY, W, H - HY), with: .color(Color(red: 5 / 255, green: 7 / 255, blue: 13 / 255)))
        ctx.fill(rect(0, HY, W, H - HY), with: .linearGradient(
            Gradient(colors: [rgb(s.sky[2], 0.55 * 0.55), rgb(s.sky[0], 0.55)]),
            startPoint: CGPoint(x: 0, y: HY), endPoint: CGPoint(x: 0, y: H)))

        towers(&ctx)

        // street line
        ctx.fill(rect(0, HY, W, 1), with: .color(rgb([201, 211, 224], 0.35 + s.dawn * 0.4)))
        lamps(&ctx)
        scene(&ctx)

        // ripples
        var ripples = Path()
        var y = HY + 5
        while y < H {
            let off = sin(m * 0.8 + y * 0.35) * 18
            ripples.addRect(CGRect(x: off - 20, y: y, width: W + 40, height: 1))
            y += 5
        }
        ctx.fill(ripples, with: .color(rgb(s.sky[1], 0.18)))
        ctx.fill(rect(0, H - 70, W, 70), with: .linearGradient(
            Gradient(colors: [Color(red: 5 / 255, green: 7 / 255, blue: 13 / 255, opacity: 0), Color(red: 5 / 255, green: 7 / 255, blue: 13 / 255)]),
            startPoint: CGPoint(x: 0, y: H - 70), endPoint: CGPoint(x: 0, y: H)))
        rain(&ctx)

        if s.week > 0.01 { weekMarks(base, sx: sx, sy: sy) }
    }

    private func skyFx(_ ctx: inout GraphicsContext) {
        let e = s.env, W = City.W, HY = City.HY
        if e.sun > 0.01 {
            let sunY = HY + 24 - e.sun * 230, sunX = 92.0
            ctx.fill(rect(0, 0, W, HY), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 214 / 255, blue: 150 / 255, opacity: 0.75), Color(red: 1, green: 170 / 255, blue: 110 / 255, opacity: 0)]),
                center: CGPoint(x: sunX, y: sunY), startRadius: 4, endRadius: 120))
            ctx.fill(circle(sunX, sunY, 16), with: .color(Color(red: 1, green: 232 / 255, blue: 190 / 255, opacity: 0.95)))
        }
        if e.stars > 0.01 {
            for (x, y, r, p) in City.stars {
                ctx.fill(rect(x, y, r, r), with: .color(Color(red: 230 / 255, green: 236 / 255, blue: 1, opacity: e.stars * (0.45 + 0.45 * sin(m * 1.6 + p)))))
            }
        }
        if e.moon > 0.01 {
            let moonGlow = Color(red: 220 / 255, green: 228 / 255, blue: 245 / 255)
            ctx.fill(rect(260, 30, 130, 130), with: .radialGradient(
                Gradient(colors: [moonGlow.opacity(0.18 * e.moon), moonGlow.opacity(0)]),
                center: CGPoint(x: 322, y: 92), startRadius: 6, endRadius: 50))
            var c = ctx
            c.clip(to: circle(322, 92, 11))
            var crescent = rect(300, 70, 44, 44)
            crescent.addPath(circle(328, 87, 10))
            c.fill(crescent, with: .color(Color(red: 232 / 255, green: 236 / 255, blue: 246 / 255, opacity: e.moon)), style: FillStyle(eoFill: true))
        }
        if e.clouds > 0.01 {
            let color = rgb([s.sky[1][0] + 30, s.sky[1][1] + 30, s.sky[1][2] + 34], 0.5 * e.clouds)
            for (x0, y, r) in City.clouds {
                let x = (x0 + m * 7).truncatingRemainder(dividingBy: W + 160) - 80
                var p = Path()
                p.addEllipse(in: ellipse(x, y, r, r * 0.32))
                p.addEllipse(in: ellipse(x + r * 0.5, y - r * 0.18, r * 0.55, r * 0.3))
                p.addEllipse(in: ellipse(x - r * 0.45, y + 2, r * 0.5, r * 0.24))
                ctx.fill(p, with: .color(color))
            }
        }
    }

    private func towers(_ ctx: inout GraphicsContext) {
        let HY = City.HY, H = City.H
        let towerCol = rgb([7 + 23 * s.dawn, 10 + 27 * s.dawn, 20 + 32 * s.dawn])
        let towerRefl = rgb([7 + 23 * s.dawn, 10 + 27 * s.dawn, 20 + 32 * s.dawn], 0.5)
        let limitY = HY - City.limit
        let overWarm = [242 + 13 * s.week, 169 - 77 * s.week, 59 + 13 * s.week]
        let amber = [242.0, 169, 59]

        var bodies = Path(), reflections = Path(), dark = Path()
        for t in s.towers where t.h >= 2 {
            bodies.addRect(CGRect(x: t.x, y: HY - t.h, width: t.w, height: t.h))
            reflections.addRect(CGRect(x: t.x, y: HY, width: t.w, height: min(t.h * 0.35, H - HY)))
        }
        ctx.fill(bodies, with: .color(towerCol))
        ctx.fill(reflections, with: .color(towerRefl))
        // lit windows batched by alpha step (16 steps) and colour (normal / over the limit)
        var lit: [Int: Path] = [:], litRefl: [Int: Path] = [:]
        var glows: [(CGPoint, Double)] = []
        let shopAlpha = 0.5 * night * (1 - s.week)

        for (ti, t) in s.towers.enumerated() where t.h >= 2 {
            if shopAlpha > 0.01 && t.h >= 30 {
                ctx.fill(rect(t.x + 1, HY - 26, t.w - 2, 26), with: .linearGradient(
                    Gradient(colors: [rgb(amber, 0), rgb(amber, shopAlpha)]),
                    startPoint: CGPoint(x: 0, y: HY - 26), endPoint: CGPoint(x: 0, y: HY)))
            }
            let cols = Int(floor((t.w - 8) / 8)), rows = Int(floor((t.h - 40) / 10))
            guard cols > 0, rows > 0 else { continue }
            for c in 0..<cols {
                for r in 0..<rows {
                    let p = City.winXY(t, c, r)
                    let on = max(0, min(1, (t.lit - City.hash(Double(ti), Double(c), Double(r))) * 9))
                    let gl = glow[Win(t: ti, c: c, r: r)] ?? 0
                    let over = s.week > 0.01 && p.y < limitY
                    dark.addRect(CGRect(x: p.x, y: p.y, width: 4, height: 5))
                    let a = max(on * 0.85, gl)
                    if a > 0.01 {
                        let key = Int((a * 16).rounded()) * 2 + (over ? 1 : 0)
                        lit[key, default: Path()].addRect(CGRect(x: p.x, y: p.y, width: 4, height: 5))
                        let ry = HY + (HY - p.y) * 0.35
                        if ry < H { litRefl[key, default: Path()].addRect(CGRect(x: p.x, y: ry, width: 4, height: 7)) }
                    }
                    if gl > 0.05 { glows.append((p, gl)) }
                }
            }
        }
        ctx.fill(dark, with: .color(rgb([30, 42, 74], 0.55 * (1 - s.dawn * 0.6))))
        for (key, path) in lit {
            let a = Double(key / 2) / 16
            let col = key % 2 == 1 ? overWarm : amber
            ctx.fill(path, with: .color(rgb(col, a)))
            if let refl = litRefl[key] { ctx.fill(refl, with: .color(rgb(col, a * 0.22))) }
        }
        for (p, gl) in glows {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 28, height: 29)), with: .radialGradient(
                Gradient(colors: [rgb(amber, 0.55 * gl), rgb(amber, 0)]),
                center: CGPoint(x: p.x + 2, y: p.y + 2.5), startRadius: 1, endRadius: 14))
            ctx.fill(rect(p.x - 1, p.y - 1, 6, 7), with: .color(rgb([255, 214, 150], gl)))
        }
    }

    private func lamps(_ ctx: inout GraphicsContext) {
        let a = 1 - s.week, HY = City.HY
        guard a > 0.01 else { return }
        for x in [44.0, 138, 232, 326] {
            let lampGlow = Color(red: 1, green: 200 / 255, blue: 120 / 255)
            ctx.fill(rect(x - 30, HY - 64, 70, 64), with: .radialGradient(
                Gradient(colors: [lampGlow.opacity(0.55 * night * a), lampGlow.opacity(0)]),
                center: CGPoint(x: x + 5, y: HY - 30), startRadius: 1, endRadius: 34))
            ctx.fill(rect(x, HY - 30, 1.5, 30), with: .color(ink.opacity(a)))
            ctx.fill(rect(x, HY - 31, 7, 1.5), with: .color(ink.opacity(a)))
            ctx.fill(rect(x + 5, HY - 30, 3, 2), with: .color(Color(red: 1, green: 214 / 255, blue: 150 / 255, opacity: (0.3 + 0.7 * night) * a)))
        }
    }

    private func rain(_ ctx: inout GraphicsContext) {
        let a = s.env.rain
        guard a > 0.01 else { return }
        var p = Path()
        for (hx, hy) in City.drops {
            let x = (hx * City.W + m * 70).truncatingRemainder(dividingBy: City.W)
            let y = (hy * City.H + m * 560).truncatingRemainder(dividingBy: City.H)
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x - 2.5, y: y + 10))
        }
        ctx.stroke(p, with: .color(Color(red: 190 / 255, green: 205 / 255, blue: 235 / 255, opacity: 0.35 * a)), lineWidth: 1)
    }

    /// Dashed daily limit line and day names, drawn unscaled so the text stays sharp.
    private func weekMarks(_ base: GraphicsContext, sx: Double, sy: Double) {
        var ctx = base
        ctx.opacity = s.week
        let limitY = (City.HY - City.limit) * sy
        var line = Path()
        line.move(to: CGPoint(x: 12 * sx, y: limitY + 0.5))
        line.addLine(to: CGPoint(x: (City.W - 12) * sx, y: limitY + 0.5))
        let silver = Color(red: 201 / 255, green: 211 / 255, blue: 224 / 255)
        ctx.stroke(line, with: .color(silver.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        ctx.draw(Text("onboarding_daily_limit".localized).font(.system(size: 12)).foregroundColor(silver.opacity(0.85)),
                 at: CGPoint(x: 14 * sx, y: limitY - 4), anchor: .bottomLeading)
        for (i, ti) in City.weekTowers.enumerated() {
            let t = s.towers[ti]
            let color = i == 4 ? Color(red: 1, green: 138 / 255, blue: 122 / 255) : silver.opacity(0.8)
            ctx.draw(Text(Self.dayNames[i]).font(.system(size: 12, weight: .semibold)).foregroundColor(color),
                     at: CGPoint(x: (t.x + t.w / 2) * sx, y: (City.HY + 16) * sy), anchor: .center)
        }
    }

    /// Short weekday names in the app's language, Monday first.
    static let dayNames: [String] = {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard symbols.count == 7 else { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] }
        return Array(symbols[1...]) + [symbols[0]]
    }()

    // MARK: Street scenes

    private func scene(_ ctx: inout GraphicsContext) {
        guard s.week <= 0.5 else { return }
        let HY = City.HY, st = reduce ? 0 : t
        switch page {
        case .welcome:
            movie(&ctx)
        case .add:
            let L = reduce ? 1.9 : t.truncatingRemainder(dividingBy: 6.4)
            var cx = L < 1.6 ? -60 + 190 * (1 - pow(1 - L / 1.6, 3)) : 130
            if L > 2.9 { let k = min(1, (L - 2.9) / 1.5); cx = 130 + 420 * k * k }
            let px = max(178, 262 - 44 * L)
            if L < 2.3 {
                person(&ctx, px, HY, Pose(walk: px > 178, ph: L * 9, dir: -1, alpha: L > 1.95 ? 1 - (L - 1.95) / 0.35 : 1))
            }
            taxi(&ctx, cx, HY)
        case .voice:
            let x = (60 + st * 26).truncatingRemainder(dividingBy: City.W + 60) - 30
            person(&ctx, x, HY, Pose(walk: true, ph: st * 7, dir: 1, eat: true))
        case .smart:
            if let w = walker { person(&ctx, w.x, HY, Pose(walk: true, ph: st * 6, dir: -1, bags: true)) }
        default:
            break
        }
    }

    typealias Pose = StreetCast.Pose

    private func person(_ ctx: inout GraphicsContext, _ x: Double, _ y: Double, _ o: Pose) {
        StreetCast.person(ctx, x, y, o, color: ink, reduce: reduce)
    }

    private func taxi(_ ctx: inout GraphicsContext, _ x: Double, _ y: Double) {
        StreetCast.taxi(ctx, x, y, wheel: ink)
    }

    /// A wall screen on tower 5 plays a "movie"; a viewer on a bench watches with popcorn.
    private func movie(_ ctx: inout GraphicsContext) {
        let tw = s.towers[5], HY = City.HY
        guard tw.h >= 150 else { return }
        let tt = reduce ? 0 : t
        let x = tw.x + 5, y = HY - 132, w = tw.w - 10, h = 30.0
        let scenes: [[Double]] = [[70, 130, 210], [230, 150, 70], [90, 190, 175], [210, 90, 110]]
        let c = scenes[Int(tt / 1.8) % 4]
        let fl = reduce ? 1 : 0.85 + 0.15 * sin(tt * 23) * sin(tt * 7)
        var cast = Path()
        cast.move(to: CGPoint(x: x, y: y + h)); cast.addLine(to: CGPoint(x: x + w, y: y + h))
        cast.addLine(to: CGPoint(x: x + w + 24, y: HY)); cast.addLine(to: CGPoint(x: x - 24, y: HY)); cast.closeSubpath()
        ctx.fill(cast, with: .linearGradient(Gradient(colors: [rgb(c, 0.22 * fl), rgb(c, 0)]),
                                             startPoint: CGPoint(x: 0, y: y + h), endPoint: CGPoint(x: 0, y: HY)))
        ctx.fill(rect(x - 2, y - 2, w + 4, h + 4), with: .color(ink))
        ctx.fill(rect(x, y, w, h), with: .color(rgb(c.map { $0 * fl })))
        ctx.fill(rect(x, y + h * 0.62, w, h * 0.38), with: .color(rgb(c.map { min(255, $0 * 1.5) }, 0.9)))
        let shadowX = x + (tt * 14).truncatingRemainder(dividingBy: w + 10) - 5
        let sx0 = max(x, shadowX), sw = min(5, x + w - shadowX)
        if sw > 0 { ctx.fill(rect(sx0, y + h * 0.4, sw, h * 0.3), with: .color(Color(red: 10 / 255, green: 12 / 255, blue: 20 / 255, opacity: 0.8))) }

        // viewer on a bench, seen from behind, with popcorn
        let bx = tw.x + tw.w / 2 - 6
        ctx.fill(rect(bx - 14, HY - 9, 30, 2.4), with: .color(ink))
        ctx.fill(rect(bx - 12, HY - 7, 2, 7), with: .color(ink))
        ctx.fill(rect(bx + 12, HY - 7, 2, 7), with: .color(ink))
        ctx.fill(Path(roundedRect: CGRect(x: bx - 4, y: HY - 21, width: 10, height: 13), cornerRadius: 4), with: .color(ink))
        ctx.fill(circle(bx + 1, HY - 24.5, 3.4), with: .color(ink))
        ctx.fill(rect(bx + 8, HY - 15, 5, 6), with: .color(Color(red: 232 / 255, green: 228 / 255, blue: 220 / 255)))
        let red = Color(red: 1, green: 92 / 255, blue: 72 / 255)
        ctx.fill(rect(bx + 9.2, HY - 15, 1.2, 6), with: .color(red))
        ctx.fill(rect(bx + 11.4, HY - 15, 1.2, 6), with: .color(red))
        var pop = Path()
        pop.addArc(center: CGPoint(x: bx + 10.5, y: HY - 15.5), radius: 2.2, startAngle: .radians(.pi), endAngle: .radians(0), clockwise: false)
        ctx.fill(pop, with: .color(Color(red: 1, green: 241 / 255, blue: 196 / 255)))
    }
}

// MARK: - Overlay (tags, neon signs, budget figure, transcript)

enum OnboardingPalette {
    static let ink = Color(red: 5 / 255, green: 7 / 255, blue: 13 / 255)
    static let fg = Color(red: 238 / 255, green: 241 / 255, blue: 246 / 255)
    static let amber = Color(red: 242 / 255, green: 169 / 255, blue: 59 / 255)
    static let silver = Color(red: 201 / 255, green: 211 / 255, blue: 224 / 255)
    static let body = Color(red: 195 / 255, green: 203 / 255, blue: 218 / 255)
    static let dotOff = Color(red: 58 / 255, green: 69 / 255, blue: 96 / 255)

    /// Big Shoulders Display (bundled, OFL) for titles: 800 by default, 600 for small labels.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .custom("Big Shoulders Display", fixedSize: size).weight(weight)
    }
}

private struct CityOverlay: View {
    let frame: CityFrame
    let sx: Double
    let sy: Double

    private var t: Double { frame.t }

    private func fade(_ at: Double, _ dur: Double = 0.5) -> Double {
        frame.reduce ? 1 : max(0, min(1, (t - at) / dur))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            switch frame.page {
            case .welcome:
                floating("onboarding_tag_cinema", "onboarding_tag_expense", chip: "onboarding_chip_fun", at: 1.4, chipAt: 2.2)
            case .add:
                anchored(City.taxi, "onboarding_tag_taxi_work", "onboarding_tag_expense_added", at: 0.7)
            case .voice:
                voice
            case .smart:
                signs
                floating("onboarding_tag_groceries", "onboarding_tag_expense", chip: "onboarding_chip_food", at: 0.4, chipAt: 1.5)
            case .budget:
                VStack(alignment: .leading, spacing: 2) {
                    Text("62%")
                        .font(OnboardingPalette.display(46))
                        .monospacedDigit()
                        .foregroundStyle(OnboardingPalette.fg)
                    Text("onboarding_budget_left".localized)
                        .font(.system(size: 14))
                        .foregroundStyle(OnboardingPalette.silver)
                }
                .opacity(fade(0.6))
                .offset(x: 24 * sx, y: 84 * sy)
            case .privacy:
                anchored(City.taxi, "onboarding_tag_iphone", "onboarding_tag_icloud", at: 1.2)
            }
        }
        .allowsHitTesting(false)
    }

    private func tagBox(_ title: String, _ sub: String, chip: String? = nil, chipOn: Double = 0) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.localized).font(.system(size: 13, weight: .semibold)).foregroundStyle(OnboardingPalette.fg)
            Text(sub.localized).font(.system(size: 13)).foregroundStyle(OnboardingPalette.amber)
            if let chip {
                Text(chip.localized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.ink)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(OnboardingPalette.amber, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 3)
                    .opacity(chipOn)
                    .offset(y: 4 * (1 - chipOn))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(OnboardingPalette.ink.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A tag pinned next to a window: on its right, or on its left when the window is past the middle.
    @ViewBuilder
    private func anchored(_ win: Win, _ title: String, _ sub: String, at: Double) -> some View {
        let tower = frame.s.towers[win.t]
        let p = City.winXY(tower, win.c, win.r)
        let left = p.x > 200
        let tick = Rectangle().fill(OnboardingPalette.silver.opacity(0.7)).frame(width: 16, height: 1)
        let row = HStack(spacing: 8) {
            if left { tagBox(title, sub); tick } else { tick; tagBox(title, sub) }
        }
        .fixedSize()
        .opacity(fade(at))
        // centre the row vertically on the window
        let y = (p.y + 2.5) * sy
        if left {
            row.frame(width: max(0, (p.x - 4) * sx), height: 0, alignment: .trailing)
                .offset(y: y)
        } else {
            row.frame(height: 0, alignment: .leading)
                .offset(x: (p.x + 8) * sx, y: y)
        }
    }

    /// A tag that floats above the walking person.
    @ViewBuilder
    private func floating(_ title: String, _ sub: String, chip: String, at: Double, chipAt: Double) -> some View {
        if let w = frame.walker {
            let chipOn = frame.reduce ? 1 : max(0, min(1, (t - chipAt) / 0.4))
            tagBox(title, sub, chip: chip, chipOn: chipOn)
                .frame(width: 0, height: 0, alignment: .bottom)
                .position(x: max(52, min(City.W - 52, w.x)) * sx, y: (w.y - 6) * sy)
                .opacity(fade(at))
        }
    }

    private var signs: some View {
        ForEach(Array([(3, "onboarding_sign_food"), (5, "onboarding_sign_transport"), (7, "onboarding_sign_health")].enumerated()), id: \.offset) { i, item in
            let tower = frame.s.towers[item.0]
            Text(item.1.localized.uppercased())
                .font(OnboardingPalette.display(14, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(red: 1, green: 215 / 255, blue: 154 / 255))
                .shadow(color: OnboardingPalette.amber.opacity(0.9), radius: 3)
                .shadow(color: OnboardingPalette.amber.opacity(0.5), radius: 8)
                .fixedSize()
                .position(x: (tower.x + tower.w / 2) * sx, y: (City.HY - tower.h - 14) * sy)
                .opacity(flicker(0.5 + Double(i) * 0.26))
        }
    }

    private func flicker(_ at: Double) -> Double {
        if frame.reduce { return 1 }
        let k = t - at
        guard k >= 0 else { return 0 }
        let seq = [1, 0.2, 1, 0.4, 1]
        return seq[min(seq.count - 1, Int(k / 0.07))]
    }

    private var voice: some View {
        let script = VoiceScript.current
        let shown = script.typed(at: t)
        let words = [("onboarding_tag_coffee", City.coffee), ("onboarding_tag_taxi", City.taxi), ("onboarding_tag_lunch", City.lunch)]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                anchored(words[i].1, words[i].0, "onboarding_tag_expense", at: script.lightTimes[i])
            }
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.amber)
                Text(String(script.text.prefix(shown)))
                    .font(.system(size: 15))
                    .foregroundStyle(OnboardingPalette.fg)
                    .lineLimit(1)
            }
            .offset(x: 24 * sx, y: 446 * sy - 9)
        }
    }
}
