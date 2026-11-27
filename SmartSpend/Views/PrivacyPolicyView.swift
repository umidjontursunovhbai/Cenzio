import SwiftUI

/// Settings > Privacy policy. Three layers: a drawn data map (where your records live),
/// a list of what leaves the iPhone and when, and the full policy in collapsed sections.
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []

    private let effectiveDate = "27 October 2026"

    var body: some View {
        Group { // pushed from Settings: the Settings stack gives the back button
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    PrivacyDataMap()
                        .padding(.top, 18)
                    leavesSection
                        .padding(.top, 34)
                    policySection
                        .padding(.top, 34)
                    contactSection
                        .padding(.top, 34)
                    Text("Effective \(effectiveDate). Covers the current version of Cenzio.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(NightGround())
            .navigationTitle("privacy_policy".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The big Big Shoulders title in the page is the visible title.
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }

            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Privacy")
                .font(NightTheme.display(46, weight: .heavy, relativeTo: .largeTitle))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Text("Your spending stays on your iPhone and in your own iCloud. Here is exactly what leaves, and when.")
                .font(.body)
                .foregroundStyle(NightTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.top, 2)
    }

    // MARK: - What leaves your iPhone

    private var leavesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NightSectionHeader(title: "What leaves your iPhone")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(Self.leaves.enumerated()), id: \.element.title) { index, row in
                    if index > 0 { hairline(leading: 0) }
                    leaveRow(row)
                }
            }
            .padding(.horizontal, 16)
            .nightGroup()
        }
    }

    private func leaveRow(_ row: LeaveRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusChip(text: row.status, style: row.style)
            }
            Text(row.detail)
                .font(.footnote)
                .foregroundStyle(NightTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Full policy

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NightSectionHeader(title: "The full policy")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(Self.sections.enumerated()), id: \.element.title) { index, section in
                    if index > 0 { hairline(leading: 60) }
                    policyRow(section)
                }
            }
            .nightGroup()
        }
    }

    private func policyRow(_ section: PolicySection) -> some View {
        let isOpen = expanded.contains(section.title)
        let tint = section.destructive ? Color(.systemRed) : NightTheme.accent
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    if isOpen { expanded.remove(section.title) } else { expanded.insert(section.title) }
                }
            } label: {
                HStack(spacing: 12) {
                    section.icon.view(size: 17)
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .background(section.destructive ? AnyShapeStyle(Color(.systemRed).opacity(0.14)) : AnyShapeStyle(NightTheme.iconFill),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text(section.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(section.destructive ? Color(.systemRed) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HeroIcon("chevron-right", size: 13)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")

            if isOpen {
                Text(section.text)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 60)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Contact

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NightSectionHeader(title: "Questions", figure: .snacker)
                .padding(.horizontal, 4)

            Text("Write to Cenzio support about this policy or your data. Your email provider handles the message; it is used only to answer you.")
                .font(.subheadline)
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            Link(destination: URL(string: "mailto:umidjon.muydinov@icloud.com")!) {
                HStack(spacing: 10) {
                    HeroIcon("envelope", size: 19)
                    Text("umidjon.muydinov@icloud.com")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                }
                .foregroundStyle(NightTheme.accent)
                .padding(.horizontal, 20)
                .frame(minHeight: 52)
                .background(NightTheme.glassFill, in: Capsule())
                .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens your email app")
        }
    }

    private func hairline(leading: CGFloat) -> some View {
        Rectangle()
            .fill(NightTheme.hair)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }

    // MARK: - Content

    private static let leaves: [LeaveRow] = [
        LeaveRow(title: "Your records", status: "Your iCloud", style: .solid,
                 detail: "Synced to the private iCloud of the account on this iPhone. Cenzio's developer cannot read it."),
        LeaveRow(title: "Voice recordings", status: "Never", style: .muted,
                 detail: "Turned into text on this iPhone, then deleted."),
        LeaveRow(title: "Text for AI drafts", status: "Only with your OK", style: .plain,
                 detail: "The spoken text, category names, currency and date go through Cenzio's server to OpenRouter/OpenAI. The server does not store them."),
        LeaveRow(title: "Your Apple name and email", status: "Never", style: .muted,
                 detail: "Kept in this iPhone's Keychain."),
        LeaveRow(title: "Exports", status: "When you share", style: .plain,
                 detail: "Made only when you ask. You choose where they go."),
        LeaveRow(title: "Tracking, ads, analytics", status: "None", style: .muted,
                 detail: "No third-party ads or analytics. Your data is never sold."),
    ]

    private static let sections: [PolicySection] = [
        PolicySection(icon: .hero("wallet"), title: "What Cenzio stores",
                      text: "Cenzio stores the expenses, categories, budgets, spending goals, monthly salary values, recurring expenses, archived expenses, learned suggestions, and preferences you add or create in the app."),
        PolicySection(icon: .symbol("iphone"), title: "Stored on this iPhone",
                      text: "Your Cenzio records are saved locally in Apple App Group storage on your device and shared only with Cenzio's own widgets."),
        PolicySection(icon: .symbol("icloud"), title: "iCloud sync",
                      text: "Your records are copied to the private iCloud database of the iCloud account signed in on this iPhone, so your other devices with the same account stay up to date. Apple stores this data under its iCloud terms; Cenzio's developer cannot read it. Remove it in the Settings app under your name > iCloud > Manage Storage."),
        PolicySection(icon: .symbol("mic"), title: "Voice recording",
                      text: "Recording starts only after you hold and pull the + button, or tap a microphone, and grant permission. Audio is kept in a temporary protected file on this iPhone, transcribed locally after Stop, and deleted after transcription or cancellation. The first use may download an Apple speech model. Recorded audio is not uploaded. Keyboard dictation follows your iPhone's own settings."),
        PolicySection(icon: .hero("arrow-up-tray"), title: "AI expense drafts",
                      text: "The first time you use AI expense preparation, the app asks permission to send recognized text, current category names and IDs, currency, reference date and timezone through Cenzio's server to OpenRouter/OpenAI. After you agree, stopping a recording automatically sends this context for an AI draft. Past expenses, salary, budgets and audio are not sent. Provider retention policies apply; this is not a zero-retention guarantee. Cenzio's server does not store or log this text. Nothing is saved until you review and tap Save."),
        PolicySection(icon: .symbol("key"), title: "No keys on your iPhone",
                      text: "The AI provider key stays on Cenzio's server. The app stores no AI credential and sends no account or device identifier with the request."),
        PolicySection(icon: .hero("arrow-down-tray"), title: "Imports and exports",
                      text: "CSV imports are read and processed on your device. Export files are created in Cenzio's local app storage only when you request an export. You decide if and where an export is shared."),
        PolicySection(icon: .symbol("person.crop.circle"), title: "Sign in with Apple",
                      text: "Cenzio asks you to sign in with Apple when it opens. It keeps only Apple's anonymous user ID and, if you share them, your name and email, stored in this iPhone's Keychain. They are not sent to Cenzio's developer. Stop using your Apple ID with Cenzio in the Settings app under your name > Sign-In & Security."),
        PolicySection(icon: .symbol("eye.slash"), title: "No tracking or ads",
                      text: "Cenzio does not track you across apps or websites, sell your data, show third-party ads, or include third-party analytics in the current build."),
        PolicySection(icon: .hero("trash"), title: "Delete your data", destructive: true,
                      text: "Clear All Data removes Cenzio records from this iPhone and resets app preferences. Copies already in your iCloud and on your other devices stay there, and exports you saved elsewhere are not deleted."),
    ]
}

// MARK: - Models

private struct LeaveRow {
    let title: String
    let status: String
    let style: StatusChip.Style
    let detail: String
}

private enum PolicyIcon {
    case hero(String)
    case symbol(String)

    @ViewBuilder
    func view(size: CGFloat) -> some View {
        switch self {
        case .hero(let name):
            HeroIcon(name, size: size)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size - 1, weight: .regular))
                .frame(width: size, height: size)
        }
    }
}

private struct PolicySection {
    let icon: PolicyIcon
    let title: String
    var destructive = false
    let text: String
}

/// Where a kind of data goes: solid when it is copied (to your iCloud), plain when it
/// leaves only on your action, muted when it never leaves.
private struct StatusChip: View {
    enum Style { case solid, plain, muted }

    let text: String
    let style: Style

    /// Text on an accent fill: ink at night, white by day.
    private static let inverse = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(NightTheme.ink) : .white })

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(style == .solid ? Self.inverse : style == .muted ? NightTheme.secondaryLabel : NightTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(style == .solid ? AnyShapeStyle(NightTheme.accent) : AnyShapeStyle(NightTheme.glassFill), in: Capsule())
            .overlay(Capsule().stroke(style == .solid ? Color.clear : NightTheme.glassLine, lineWidth: 1))
    }
}

// MARK: - Data map

/// The night street as a map of your data: the lit tower is your iPhone (each lit window a
/// record), the locked cloud is your private iCloud, the dark house is Cenzio, which keeps
/// no copy. Drawn in a 353 x 236 design box and scaled to the width.
///
/// One endless loop (`period` s): a person walks out of the tower to a somsa stall, pays and
/// gets a bag; a "Food" chip flies into the tower and lights a window while the iCloud lock
/// blinks. A taxi picks them up and drives back to the tower; a "Transport" chip flies in the
/// same way. They walk in the door, the taxi leaves, and the new lights fade back. The house
/// stays dark. Steps follow the distance walked, so feet never slide. Reduce Motion: drawn lit
/// and still, with nobody on the street.
private struct PrivacyDataMap: View {
    static let size = CGSize(width: 353, height: 236)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var start: Date?
    @State private var visible = false

    private static let lit = [1, 3, 4, 6, 9, 10, 12, 15, 17, 18, 21, 23, 26, 28, 30]

    // MARK: Timeline (seconds into the loop)

    static let period = 16.2
    /// Street line, the tower door and the stall.
    private static let ground = 206.0, doorX = 69.0, stallX = 164.0
    /// The person is drawn at 0.9x (about 23 pt tall).
    private static let personScale = 0.9
    private static let walkOut = (start: 0.2, length: 4.0)          // door -> stall
    private static let billAt = 4.4, bagAt = 5.0, bagsInHand = 5.5
    private static let taxiIn = (start: 6.2, length: 2.0)           // from the right to the stall
    private static let turnAt = 8.3, getIn = (start: 8.5, length: 0.4)
    private static let ride = (start: 9.2, length: 2.2)             // stall -> tower
    private static let getOut = (start: 11.6, length: 0.3)
    private static let walkIn = (start: 11.8, length: 1.6)          // taxi -> door
    private static let enter = (start: 13.2, length: 0.4)
    private static let taxiOut = (start: 13.6, length: 1.8)         // away to the left
    private static let lightsOff = (start: 14.8, length: 1.2)
    /// Taxi body left edge: arriving, at the stall, at the tower, gone.
    private static let taxiFrom = 360.0, taxiStall = stallX - 23, taxiTower = 78.0, taxiGone = -130.0
    private static var getOutX: Double { taxiTower + 23 }

    /// A record chip: where it pops up, when, and the window it lights.
    private struct Record {
        let label: String
        let from: CGPoint
        let pop: Double
        let window: Int
        var lands: Double { pop + 0.5 + 1.0 }
    }

    private static let records = [
        Record(label: "Food", from: CGPoint(x: 192, y: 166), pop: 5.2, window: 13),
        Record(label: "Transport", from: CGPoint(x: getOutX, y: 172), pop: 11.6, window: 19),
    ]

    var body: some View {
        GeometryReader { geo in
            let k = min(1.2, geo.size.width / Self.size.width)
            map
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .scaleEffect(k, anchor: .topLeading)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your records live on your iPhone and sync to your private iCloud. Cenzio keeps no copy.")
        .accessibilityAddTraits(.isImage)
        .onAppear {
            visible = true
            if !reduceMotion, start == nil { start = .now }
        }
        .onDisappear { visible = false }
    }

    private var animates: Bool { !reduceMotion }

    private var map: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1 / 30,
                                    paused: !animates || start == nil || !visible || scenePhase != .active)) { tl in
                let t: Double? = {
                    guard animates, let start else { return nil }
                    return tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.period)
                }()
                Canvas { ctx, _ in
                    draw(ctx, t: t)
                    if let t { drawStory(ctx, t: t) }
                }
            }

            tag("Your iPhone", "Every record lives here", tick: true)
                .offset(x: 120, y: 96)
            tag("Your iCloud", "Synced to your devices", tick: true)
                .offset(x: 164, y: 14)
            tag("Cenzio", "Keeps no copy", tick: false)
                .offset(x: 250, y: 62)
        }
        .allowsHitTesting(false)
    }

    private func tag(_ title: String, _ sub: String, tick: Bool) -> some View {
        HStack(spacing: 8) {
            if tick {
                Rectangle().fill(NightTheme.secondaryLabel.opacity(0.7)).frame(width: 14, height: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(sub).font(.system(size: 13)).foregroundStyle(NightTheme.secondaryLabel)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tagFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(NightTheme.glassLine, lineWidth: 1))
        }
    }

    private var dark: Bool { scheme == .dark }
    private var tagFill: Color { dark ? NightTheme.ink.opacity(0.88) : Color.white.opacity(0.92) }

    private func c(_ dark: Color, _ light: Color) -> Color { self.dark ? dark : light }
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // MARK: Motion helpers

    private static func prog(_ t: Double, _ from: Double, _ length: Double) -> Double {
        min(max((t - from) / length, 0), 1)
    }

    private static func smooth(_ k: Double) -> Double { k * k * (3 - 2 * k) }

    /// Share of a walk done at progress `w`: speeds up over the first 20%, steady, slows
    /// down over the last 20% (no sudden start or stop).
    private static func walkCurve(_ w: Double) -> Double {
        let r = 0.2
        if w <= 0 { return 0 }
        if w >= 1 { return 1 }
        if w < r { return w * w / (2 * r) / (1 - r) }
        if w > 1 - r { return 1 - (1 - w) * (1 - w) / (2 * r) / (1 - r) }
        return (r / 2 + (w - r)) / (1 - r)
    }

    /// Window index -> centre of that window in the tower.
    private static func windowCenter(_ i: Int) -> CGPoint {
        CGPoint(x: 31 + Double(i % 4) * 22 + 5, y: 70 + Double(i / 4) * 16 + 4)
    }

    /// 0...1 brightness of a window a record lit (0 when it is not lit by a record).
    private static func recordLight(_ i: Int, t: Double?) -> Double {
        guard let t, let r = records.first(where: { $0.window == i }) else { return 0 }
        return prog(t, r.lands, 0.3) * (1 - prog(t, lightsOff.start, lightsOff.length))
    }

    /// 0...1: the iCloud lock blinks twice right after each record lands.
    private static func lockBlink(_ t: Double?) -> Double {
        guard let t else { return 0 }
        for r in records where t >= r.lands && t < r.lands + 0.8 {
            let k = (t - r.lands) / 0.8
            return 0.5 - 0.5 * cos(k * 4 * .pi)
        }
        return 0
    }

    /// Seconds the sync line has been running in the current pulse, or nil when it rests.
    private static func syncRun(_ t: Double?) -> Double? {
        guard let t else { return nil }
        for r in records where t >= r.lands && t < r.lands + 1.6 { return t - r.lands }
        return nil
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, t: Double?) {
        let ink = NightTheme.ink
        let fg = c(NightTheme.fg, ink)
        let back = c(Self.rgb(0x0B1019), ink.opacity(0.10))
        let tower = c(Self.rgb(0x131A28), ink.opacity(0.82))
        let house = c(Self.rgb(0x111724), ink.opacity(0.55))
        let unlit = c(Self.rgb(0x1A2232), Color.white.opacity(0.16))
        let pole = c(Self.rgb(0x2A3142), ink.opacity(0.45))
        let cloud = c(Self.rgb(0x1C2436), ink.opacity(0.12))
        let warm = NightTheme.window

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path { Path(CGRect(x: x, y: y, width: w, height: h)) }
        func circle(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }

        // far skyline
        for r in [(0.0, 150.0, 20.0, 56.0), (118, 132, 34, 74), (150, 160, 40, 46), (196, 140, 22, 66), (334, 150, 19, 56)] {
            ctx.fill(rect(r.0, r.1, r.2, r.3), with: .color(back))
        }

        // your iPhone: the tower, its windows and its door
        ctx.fill(rect(20, 58, 100, 148), with: .color(tower))
        ctx.fill(rect(20, 58, 100, 1), with: .color(fg.opacity(0.22)))
        ctx.fill(rect(69, 44, 2, 14), with: .color(pole))
        for row in 0..<8 {
            for col in 0..<4 {
                let i = row * 4 + col
                let frame = rect(31 + Double(col) * 22, 70 + Double(row) * 16, 10, 8)
                ctx.fill(frame, with: .color(unlit))
                if Self.lit.contains(i) {
                    ctx.fill(frame, with: .color(warm))
                } else {
                    let on = Self.recordLight(i, t: t)
                    if on > 0 { ctx.fill(frame, with: .color(warm.opacity(on))) }
                }
            }
        }
        if t != nil {
            // the door sits between the bottom windows (x 63...75, below y 190)
            ctx.fill(rect(Self.doorX - 6, 190, 12, Self.ground - 190), with: .color(c(Self.rgb(0x060910), ink)))
        }

        // sync line to the cloud; its dashes run for a moment after each record lands
        var sync = Path()
        sync.move(to: CGPoint(x: 70, y: 42))
        sync.addCurve(to: CGPoint(x: 100, y: 38), control1: CGPoint(x: 70, y: 24), control2: CGPoint(x: 86, y: 26))
        let run = Self.syncRun(t)
        ctx.stroke(sync, with: .color(fg.opacity(run == nil ? 0.55 : 0.8)),
                   style: StrokeStyle(lineWidth: 1.4, dash: [3, 4], dashPhase: -(run ?? 0) / 1.6 * 28))

        // your iCloud, locked; the lock blinks warm when a record arrives
        for p in [circle(113, 38, 11), circle(131, 29, 15), circle(151, 36, 12),
                  Path(roundedRect: CGRect(x: 102, y: 36, width: 61, height: 13), cornerRadius: 6.5)] {
            ctx.fill(p, with: .color(cloud))
        }
        let blink = Self.lockBlink(t)
        if blink > 0 {
            ctx.fill(circle(131.5, 35, 11), with: .radialGradient(
                Gradient(colors: [warm.opacity(0.55 * blink), warm.opacity(0)]),
                center: CGPoint(x: 131.5, y: 35), startRadius: 0, endRadius: 11))
        }
        let lockColor = blink > 0.5 ? warm : fg
        ctx.fill(Path(roundedRect: CGRect(x: 126.5, y: 34, width: 10, height: 8), cornerRadius: 1.6), with: .color(lockColor))
        var shackle = Path()
        shackle.move(to: CGPoint(x: 128.5, y: 34))
        shackle.addLine(to: CGPoint(x: 128.5, y: 31.4))
        shackle.addArc(center: CGPoint(x: 131.5, y: 31.4), radius: 3, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        shackle.addLine(to: CGPoint(x: 134.5, y: 34))
        ctx.stroke(shackle, with: .color(lockColor), lineWidth: 1.5)

        // Cenzio: a dark house with no lit windows
        ctx.fill(rect(262, 126, 68, 80), with: .color(house))
        var roof = Path()
        roof.move(to: CGPoint(x: 258, y: 126)); roof.addLine(to: CGPoint(x: 296, y: 104)); roof.addLine(to: CGPoint(x: 334, y: 126)); roof.closeSubpath()
        ctx.fill(roof, with: .color(house))
        for w in [(274.0, 140.0), (306, 140), (274, 162), (306, 162)] {
            ctx.fill(rect(w.0, w.1, 12, 10), with: .color(c(Color.white.opacity(0.05), Color.white.opacity(0.18))))
        }
        ctx.fill(rect(289, 184, 14, 22), with: .color(c(Self.rgb(0x060910), ink.opacity(0.8))))

        // street lamp with warm glow
        var glow = Path()
        glow.move(to: CGPoint(x: 200, y: 154)); glow.addLine(to: CGPoint(x: 270, y: 154))
        glow.addLine(to: CGPoint(x: 256, y: 206)); glow.addLine(to: CGPoint(x: 214, y: 206)); glow.closeSubpath()
        ctx.fill(glow, with: .radialGradient(Gradient(colors: [warm.opacity(dark ? 0.32 : 0.22), warm.opacity(0)]),
                                             center: CGPoint(x: 235, y: 154), startRadius: 0, endRadius: 60))
        ctx.fill(rect(234, 150, 2, 56), with: .color(pole))
        var head = Path()
        head.move(to: CGPoint(x: 229, y: 150)); head.addLine(to: CGPoint(x: 241, y: 150))
        head.addLine(to: CGPoint(x: 239, y: 154)); head.addLine(to: CGPoint(x: 231, y: 154)); head.closeSubpath()
        ctx.fill(head, with: .color(pole))
        ctx.fill(circle(235, 154, 1.8), with: .color(warm))

        // somsa stall (only while the story plays)
        if t != nil {
            let awning = c(Self.rgb(0x8A94A8), ink.opacity(0.45))
            let counter = c(Self.rgb(0x2A3350), ink.opacity(0.7))
            ctx.fill(rect(176, 176, 34, 5), with: .color(awning))
            for x in stride(from: 176.0, to: 210, by: 7) {
                ctx.fill(rect(x, 181, 3.5, 2), with: .color(awning.opacity(0.6)))
            }
            ctx.fill(rect(178, 183, 2, 10), with: .color(pole))
            ctx.fill(rect(206, 183, 2, 10), with: .color(pole))
            ctx.fill(rect(175, 193, 36, 13), with: .color(counter))
            ctx.fill(rect(182, 196, 22, 2), with: .color(warm))
        }

        // the street
        ctx.fill(rect(0, Self.ground, Self.size.width, 1), with: .color(fg.opacity(0.22)))
    }

    /// The person, the taxi, the bill and bag, and the flying record chips at time `t`.
    private func drawStory(_ ctx: GraphicsContext, t: Double) {
        let warm = NightTheme.window
        let figure = NightTheme.figure(scheme)

        // taxi first, so the person stands in front of it on the kerb
        if let (x, left) = Self.taxiState(t) {
            var car = ctx
            if left {
                car.translateBy(x: 2 * x + 46, y: 0)
                car.scaleBy(x: -1, y: 1)
            }
            StreetCast.taxi(car, x, Self.ground, wheel: NightTheme.ink, rims: dark)
        }

        // the person
        let p = Self.personState(t)
        if p.alpha > 0 {
            let s = Self.personScale
            StreetCast.person(ctx, p.x, Self.ground + p.drop * s,
                              .init(walk: true, ph: p.ph, dir: p.dir, alpha: p.alpha, bags: t >= Self.bagsInHand, scale: s),
                              color: figure, reduce: false)
        }

        // bill to the seller, then the bag to the buyer's hand
        let bill = Self.prog(t, Self.billAt, 0.5)
        if bill > 0, bill < 1 {
            let x = Self.stallX + 4 + 16 * Self.smooth(bill)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: 193, width: 5, height: 3), cornerRadius: 0.5),
                     with: .color(warm.opacity(min(1, (1 - bill) * 4))))
        }
        let bag = Self.prog(t, Self.bagAt, 0.5)
        if bag > 0, t < Self.bagsInHand {
            let x = 188 - 18 * Self.smooth(bag)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: 190, width: 5, height: 6), cornerRadius: 1), with: .color(warm))
        }

        for r in Self.records { chip(ctx, r, t: t) }
    }

    /// Left edge of the taxi body and whether it faces left, or nil when it is off the street.
    private static func taxiState(_ t: Double) -> (Double, Bool)? {
        if t < taxiIn.start || t >= taxiOut.start + taxiOut.length { return nil }
        if t < ride.start {
            let k = prog(t, taxiIn.start, taxiIn.length)
            let e = 1 - pow(1 - k, 3) // slows to a stop
            return (taxiFrom + (taxiStall - taxiFrom) * e, true)
        }
        if t < taxiOut.start {
            let k = smooth(prog(t, ride.start, ride.length))
            return (taxiStall + (taxiTower - taxiStall) * k, true)
        }
        let k = prog(t, taxiOut.start, taxiOut.length)
        return (taxiTower + (taxiGone - taxiTower) * k * k, true) // pulls away
    }

    /// Where the person is, which way they face, how visible they are, and the walk pose.
    /// `drop` lowers the body by the height the angled legs lose, so the planted foot stays on
    /// the street line (a natural step bob).
    private struct PersonState { var x = 0.0, dir = 1.0, alpha = 0.0, ph = 0.0, drop = 0.0 }

    private static func personState(_ t: Double) -> PersonState {
        var p = PersonState()
        if t < getIn.start + getIn.length {
            // out of the door to the stall, then waiting there until the taxi comes
            let distance = stallX - doorX
            let d = distance * walkCurve(prog(t, walkOut.start, walkOut.length))
            p.x = doorX + d
            p.dir = t >= turnAt ? -1 : 1
            p.alpha = min(prog(t, 0, 0.5), 1 - prog(t, getIn.start, getIn.length))
            (p.ph, p.drop) = step(d, total: distance)
        } else if t >= getOut.start, t < enter.start + enter.length {
            // out of the taxi, back to the door, facing the way they walk (left)
            let distance = getOutX - doorX
            let d = distance * walkCurve(prog(t, walkIn.start, walkIn.length))
            p.x = getOutX - d
            p.dir = -1
            p.alpha = min(prog(t, getOut.start, getOut.length), 1 - prog(t, enter.start, enter.length))
            (p.ph, p.drop) = step(d, total: distance)
        }
        return p
    }

    /// Walk pose for `d` points walked of a `total`-point walk. The stride is fitted so the
    /// walk is a whole number of steps (feet together at both ends). Over each step the swing
    /// is linear in distance, so the planted foot moves back exactly as fast as the body moves
    /// forward: no sliding. Returns the `StreetCast.person` phase and the body drop in units.
    private static func step(_ d: Double, total: Double) -> (Double, Double) {
        let s = personScale
        let leg = 10.0
        let natural = 2 * leg * sin(0.5) // feet apart at the widest natural stride, in units
        let steps = max(1, (total / s / natural).rounded(.up))
        let stride = total / s / steps     // units per step, never wider than natural
        // Foot A sits at +-half a stride at each step boundary and swaps sides over a step
        // (planted while it moves back, swinging while it moves forward); foot B mirrors it.
        // Shifted half a step so the feet are together when standing (d = 0 and d = total).
        let v = (d / s / stride + 0.5).truncatingRemainder(dividingBy: 2)
        let tri = v < 1 ? 1 - 2 * v : 2 * (v - 1) - 1
        // feet at x = +-leg * sin(sw): half a stride apart at step boundaries
        let sw = asin(min(1, tri * stride / 2 / leg))
        // StreetCast swings the legs by sin(ph) * 0.5
        let ph = asin(min(1, max(-1, sw / 0.5)))
        return (ph, leg * (1 - cos(sw)))
    }

    /// A record chip: pops up, then flies on a low curve into its window, shrinking as it goes.
    private func chip(_ ctx: GraphicsContext, _ r: Record, t: Double) {
        let pop = Self.prog(t, r.pop, 0.3)
        let fly = Self.smooth(Self.prog(t, r.pop + 0.5, 1.0))
        guard pop > 0, fly < 1 else { return }
        let to = Self.windowCenter(r.window)
        let from = CGPoint(x: r.from.x, y: r.from.y - 8 * Self.smooth(pop))
        let ctrl = CGPoint(x: to.x + (from.x - to.x) * 0.3, y: max(from.y, to.y) + 6)
        let a = 1 - fly
        let pos = CGPoint(x: a * a * from.x + 2 * a * fly * ctrl.x + fly * fly * to.x,
                          y: a * a * from.y + 2 * a * fly * ctrl.y + fly * fly * to.y)
        let scale = 1 - 0.65 * fly
        let alpha = Self.smooth(pop) * (fly < 0.75 ? 1 : 1 - (fly - 0.75) / 0.25)

        var g = ctx
        g.opacity = alpha
        g.translateBy(x: pos.x, y: pos.y)
        g.scaleBy(x: scale, y: scale)
        let text = g.resolve(Text(r.label).font(.system(size: 10, weight: .semibold))
            .foregroundColor(c(NightTheme.window, NightTheme.ink)))
        let size = text.measure(in: CGSize(width: 200, height: 40))
        let w = size.width + 14, h = 17.0
        let shape = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: h / 2)
        g.fill(shape, with: .color(c(Self.rgb(0x1C2436).opacity(0.96), Color.white.opacity(0.96))))
        g.stroke(shape, with: .color(NightTheme.window.opacity(dark ? 0.55 : 0.9)), lineWidth: 1)
        g.draw(text, at: .zero, anchor: .center)
    }
}

#Preview {
    PrivacyPolicyView()
}
