import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let effectiveDate = "October 27, 2026"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    privacyHero
                    dataPath

                    policyGroup(
                        title: "Optional voice and AI drafts",
                        sections: [
                            PolicySection(icon: "lock-closed", title: "Your choice before sending",
                                          text: "Recording starts only after you hold and pull the + button, or tap a microphone, and grant permission. Audio is kept in a temporary protected file on this iPhone, transcribed locally after Stop, and deleted after transcription or cancellation. The first use may download an Apple speech model. Recorded audio is not uploaded. Keyboard dictation follows your iPhone's own settings."),
                            PolicySection(icon: "arrow-up-tray", title: "Text sent to AI only with consent",
                                          text: "The first time you use AI expense preparation, the app asks permission to send recognized text, current category names and IDs, currency, reference date and timezone through Cenzio's server to OpenRouter/OpenAI. After you agree, stopping a recording automatically sends this context for an AI draft. Past expenses, salary, budgets and audio are not sent. Provider retention policies apply; this is not a zero-retention guarantee. Cenzio's server does not store or log this text. Nothing is saved until you review and tap Save."),
                            PolicySection(icon: "key", title: "No credentials on your iPhone",
                                          text: "The AI provider key stays on Cenzio's server. The app stores no AI credential and sends no account or device identifier with the request.")
                        ]
                    )

                    policyGroup(
                        title: "Your data",
                        figure: .shopper,
                        sections: [
                            PolicySection(
                                icon: "wallet",
                                title: "What Cenzio stores",
                                text: "Cenzio stores the expenses, categories, budgets, spending goals, monthly salary values, recurring expenses, archived expenses, learned suggestions, and preferences you add or create in the app."
                            ),
                            PolicySection(
                                icon: "hand-raised",
                                title: "Stored on this iPhone",
                                text: "Your Cenzio records are saved locally in Apple App Group storage on your device and shared only with Cenzio's own widgets."
                            ),
                            PolicySection(
                                icon: "cloud",
                                title: "iCloud sync between your devices",
                                text: "Your records are copied to the private iCloud database of the iCloud account signed in on this iPhone, so your other devices with the same account stay up to date. Apple stores this data under its iCloud terms; Cenzio's developer cannot read it. Remove it in the Settings app under your name > iCloud > Manage Storage."
                            ),
                            PolicySection(
                                icon: "arrow-down-tray",
                                title: "Imports and exports",
                                text: "CSV imports are read and processed on your device. Export files are created in Cenzio's local app storage only when you request an export. You decide if and where an export is shared."
                            )
                        ]
                    )

                    policyGroup(
                        title: "Your choices",
                        sections: [
                            PolicySection(
                                icon: "eye",
                                title: "No tracking or advertising",
                                text: "Cenzio does not track you across apps or websites, sell your data, show third-party ads, or include third-party analytics in the current build."
                            ),
                            PolicySection(
                                icon: "wifi",
                                title: "Sign in with Apple",
                                text: "Cenzio asks you to sign in with Apple when it opens. It keeps only Apple's anonymous user ID and, if you share them, your name and email, stored in this iPhone's Keychain. They are not sent to Cenzio's developer. Stop using your Apple ID with Cenzio in the Settings app under your name > Sign-In & Security."
                            ),
                            PolicySection(
                                icon: "trash",
                                destructive: true,
                                title: "Delete your app data",
                                text: "Clear All Data removes Cenzio records from this iPhone and resets app preferences. Copies already in your iCloud and on your other devices stay there, and exports you saved elsewhere are not deleted."
                            )
                        ]
                    )

                    contactCard
                    updatedLabel
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 40)
            }
            .background(NightGround())
            .navigationTitle("privacy_policy".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(NightTheme.accent)
                    .iOSMinimumTapTarget()
                }
            }
        }
    }

    // MARK: - Hero: the promise stands on the street, no card

    private var privacyHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Private by default")
                .font(NightTheme.display(44, weight: .heavy, relativeTo: .largeTitle))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .capFigure(.walker, fontSize: 44, relativeTo: .largeTitle, height: 26, gap: 10)
                .accessibilityAddTraits(.isHeader)

            Text("Your spending history stays under your control.")
                .font(.body)
                .foregroundStyle(NightTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    privacyBadge(icon: "check", text: "Local storage")
                    privacyBadge(icon: "check", text: "No tracking")
                }

                VStack(alignment: .leading, spacing: 8) {
                    privacyBadge(icon: "check", text: "Local storage")
                    privacyBadge(icon: "check", text: "No tracking")
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - Data path: three stops on one line

    private var dataPath: some View {
        VStack(alignment: .leading, spacing: 14) {
            NightSectionHeader(title: "How your data moves", figure: .cyclist)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                dataPathRow(
                    icon: "document-plus",
                    title: "You add it",
                    detail: "Expenses, plans, categories, and preferences",
                    position: .first
                )
                dataPathRow(
                    icon: "phone",
                    title: "Cenzio keeps it local",
                    detail: "Saved in the app's on-device storage",
                    position: .middle
                )
                dataPathRow(
                    icon: "arrow-up-tray",
                    title: "You choose when it leaves",
                    detail: "Synced to your private iCloud; otherwise only through exports, support email, or consented AI drafts",
                    position: .last
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .nightGroup()
        }
    }

    private enum StopPosition { case first, middle, last }

    /// Text on an accent fill: ink at night, white by day.
    private static let inverse = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(NightTheme.ink) : .white })

    private func dataPathRow(icon: String, title: String, detail: String, position: StopPosition) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // The street line runs through every stop; it starts at the first and ends at the last.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(position == .first ? Color.clear : NightTheme.hair)
                        .frame(width: 1, height: 12)
                    Color.clear.frame(width: 1, height: 40)
                    Rectangle()
                        .fill(position == .last ? Color.clear : NightTheme.hair)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }

                // The last stop is filled: that is the moment you decide.
                HeroIcon(icon, size: 19)
                    .foregroundStyle(position == .last ? Self.inverse : NightTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(position == .last ? AnyShapeStyle(NightTheme.accent) : AnyShapeStyle(NightTheme.iconFill), in: Circle())
                    .padding(.top, 12)
            }
            .frame(width: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Policy groups

    private func policyGroup(title: String, figure: StreetFigure? = nil, sections: [PolicySection]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NightSectionHeader(title: title, figure: figure)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    policyRow(section)

                    if index < sections.count - 1 {
                        Rectangle()
                            .fill(NightTheme.hair)
                            .frame(height: 0.5)
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, 18)
            .nightGroup()
        }
    }

    private func policyRow(_ section: PolicySection) -> some View {
        let tint = section.destructive ? Color(.systemRed) : NightTheme.accent
        return HStack(alignment: .top, spacing: 14) {
            HeroIcon(section.icon, size: 20)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(section.destructive ? AnyShapeStyle(Color(.systemRed).opacity(0.14)) : AnyShapeStyle(NightTheme.iconFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(section.text)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Contact and footer

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            NightSectionHeader(title: "Contact", figure: .snacker)
                .padding(.horizontal, 4)

            Text("Questions about this policy or your data can be sent directly to Cenzio support. Your email and anything you include are handled by your email provider and used to respond to your request.")
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
                    HeroIcon("arrow-right", size: 15)
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

    private var updatedLabel: some View {
        Text("Effective \(effectiveDate) · This policy describes the current Cenzio build.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
    }

    private func privacyBadge(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            HeroIcon(icon, size: 14)
            Text(text)
                .lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(NightTheme.accent)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(NightTheme.glassFill, in: Capsule())
        .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
    }
}

private struct PolicySection: Identifiable {
    let icon: String
    var destructive = false
    let title: String
    let text: String

    var id: String { title }
}

#Preview {
    PrivacyPolicyView()
}
