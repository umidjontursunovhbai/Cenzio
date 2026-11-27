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
            NightSectionHeader(title: "What leaves your iPhone", figure: .cyclist)
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
/// no copy. Drawn in a 353 x 236 design box and scaled to the width. On appear the windows
/// light one by one and the sync line runs twice, then the whole thing plays back in reverse
/// and forward again, forever (ping-pong, short holds at both ends). Reduce Motion: drawn lit.
private struct PrivacyDataMap: View {
    static let size = CGSize(width: 353, height: 236)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var start: Date?

    private static let lit = [1, 3, 4, 6, 9, 10, 12, 15, 17, 18, 21, 23, 26, 28, 30]
    private static let lightStart = 0.5, lightStep = 0.11, lightFade = 0.35
    private static let flowStart = 2.1, flowTime = 3.2
    private static let total = flowStart + flowTime
    private static let holdEnd = 1.2, holdStart = 0.6

    /// Scene time for `elapsed` seconds: forward, hold, backward, hold, repeat.
    private static func pingPong(_ elapsed: Double) -> Double {
        let period = 2 * total + holdEnd + holdStart
        let u = elapsed.truncatingRemainder(dividingBy: period)
        if u < total { return u }
        if u < total + holdEnd { return total }
        if u < 2 * total + holdEnd { return 2 * total + holdEnd - u }
        return 0
    }

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
        .onAppear { if !reduceMotion, start == nil { start = .now } }
    }

    private var animates: Bool { !reduceMotion }

    private var map: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates || start == nil)) { tl in
                let t: Double = {
                    guard animates else { return Self.total }
                    guard let start else { return 0 }
                    return Self.pingPong(tl.date.timeIntervalSince(start))
                }()
                Canvas { ctx, _ in draw(ctx, t: t) }
            }

            StreetFigureView(figure: .walker, height: 24, paces: true)
                .position(x: 178, y: 206 - 12)

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

    private func draw(_ ctx: GraphicsContext, t: Double) {
        let ink = NightTheme.ink
        let fg = c(NightTheme.fg, ink)
        let back = c(Self.rgb(0x0B1019), ink.opacity(0.10))
        let tower = c(Self.rgb(0x131A28), ink.opacity(0.82))
        let house = c(Self.rgb(0x111724), ink.opacity(0.55))
        let unlit = c(Self.rgb(0x1A2232), Color.white.opacity(0.16))
        let pole = c(Self.rgb(0x2A3142), ink.opacity(0.45))
        let cloud = c(Self.rgb(0x1C2436), ink.opacity(0.12))

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path { Path(CGRect(x: x, y: y, width: w, height: h)) }
        func circle(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }

        // far skyline
        for r in [(0.0, 150.0, 20.0, 56.0), (118, 132, 34, 74), (150, 160, 40, 46), (196, 140, 22, 66), (334, 150, 19, 56)] {
            ctx.fill(rect(r.0, r.1, r.2, r.3), with: .color(back))
        }

        // your iPhone: the tower and its windows
        ctx.fill(rect(20, 58, 100, 148), with: .color(tower))
        ctx.fill(rect(20, 58, 100, 1), with: .color(fg.opacity(0.22)))
        ctx.fill(rect(69, 44, 2, 14), with: .color(pole))
        for row in 0..<8 {
            for col in 0..<4 {
                let i = row * 4 + col
                let frame = rect(31 + Double(col) * 22, 70 + Double(row) * 16, 10, 8)
                ctx.fill(frame, with: .color(unlit))
                if let order = Self.lit.firstIndex(of: i) {
                    let on = min(1, max(0, (t - Self.lightStart - Double(order) * Self.lightStep) / Self.lightFade))
                    if on > 0 { ctx.fill(frame, with: .color(NightTheme.window.opacity(on))) }
                }
            }
        }

        // sync line to the cloud, running while the clock is in its flow window
        var sync = Path()
        sync.move(to: CGPoint(x: 70, y: 42))
        sync.addCurve(to: CGPoint(x: 100, y: 38), control1: CGPoint(x: 70, y: 24), control2: CGPoint(x: 86, y: 26))
        let flow = min(max(t - Self.flowStart, 0), Self.flowTime)
        ctx.stroke(sync, with: .color(fg.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.4, dash: [3, 4], dashPhase: -flow / 1.6 * 28))

        // your iCloud, locked
        for p in [circle(113, 38, 11), circle(131, 29, 15), circle(151, 36, 12),
                  Path(roundedRect: CGRect(x: 102, y: 36, width: 61, height: 13), cornerRadius: 6.5)] {
            ctx.fill(p, with: .color(cloud))
        }
        ctx.fill(Path(roundedRect: CGRect(x: 126.5, y: 34, width: 10, height: 8), cornerRadius: 1.6), with: .color(fg))
        var shackle = Path()
        shackle.move(to: CGPoint(x: 128.5, y: 34))
        shackle.addLine(to: CGPoint(x: 128.5, y: 31.4))
        shackle.addArc(center: CGPoint(x: 131.5, y: 31.4), radius: 3, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        shackle.addLine(to: CGPoint(x: 134.5, y: 34))
        ctx.stroke(shackle, with: .color(fg), lineWidth: 1.5)

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
        ctx.fill(glow, with: .radialGradient(Gradient(colors: [NightTheme.window.opacity(dark ? 0.32 : 0.22), NightTheme.window.opacity(0)]),
                                             center: CGPoint(x: 235, y: 154), startRadius: 0, endRadius: 60))
        ctx.fill(rect(234, 150, 2, 56), with: .color(pole))
        var head = Path()
        head.move(to: CGPoint(x: 229, y: 150)); head.addLine(to: CGPoint(x: 241, y: 150))
        head.addLine(to: CGPoint(x: 239, y: 154)); head.addLine(to: CGPoint(x: 231, y: 154)); head.closeSubpath()
        ctx.fill(head, with: .color(pole))
        ctx.fill(circle(235, 154, 1.8), with: .color(NightTheme.window))

        // the street
        ctx.fill(rect(0, 206, Self.size.width, 1), with: .color(fg.opacity(0.22)))
    }
}

#Preview {
    PrivacyPolicyView()
}
