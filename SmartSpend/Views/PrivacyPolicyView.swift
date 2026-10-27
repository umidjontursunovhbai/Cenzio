import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let effectiveDate = "October 27, 2026"

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    privacyHero
                    dataPath

                    policyGroup(
                        title: "Optional voice and AI drafts",
                        sections: [
                            PolicySection(icon: "lock-closed", tint: Color.accentColor,
                                          title: "Your choice before sending",
                                          text: "Recording starts only after you hold and pull the + button, or tap a microphone, and grant permission. Audio is kept in a temporary protected file on this iPhone, transcribed locally after Stop, and deleted after transcription or cancellation. The first use may download an Apple speech model. Recorded audio is not uploaded. Keyboard dictation follows your iPhone's own settings."),
                            PolicySection(icon: "arrow-up-tray", tint: Color.accentColor,
                                          title: "Text sent to AI only with consent",
                                          text: "The first time you use AI expense preparation, the app asks permission to send recognized text, current category names and IDs, currency, reference date and timezone through the authenticated server to OpenRouter/OpenAI. After you agree, stopping a recording automatically sends this context for an AI draft. Past expenses, salary, budgets and audio are not sent. Provider retention policies apply; this is not a zero-retention guarantee. Drafts are kept temporarily in server memory for safe retries, not in the expense database. Nothing is saved until you review and tap Save."),
                            PolicySection(icon: "key", tint: Color.accentColor,
                                          title: "Disconnect any time",
                                          text: "The provider API key stays on your server. Your phone's separate revocable connection credential is stored in iOS Keychain and does not sync to iCloud Keychain. Disconnect in Voice connection to remove it and request server revocation. If your server is offline, revoke the device from the server separately.")
                        ]
                    )

                    policyGroup(
                        title: "Your data",
                        sections: [
                            PolicySection(
                                icon: "wallet",
                                tint: Color.accentColor,
                                title: "What Cenzio stores",
                                text: "Cenzio stores the expenses, categories, budgets, spending goals, monthly salary values, recurring expenses, archived expenses, learned suggestions, and preferences you add or create in the app."
                            ),
                            PolicySection(
                                icon: "hand-raised",
                                tint: Color(.systemIndigo),
                                title: "Stored on this iPhone",
                                text: "Your Cenzio records are saved locally in Apple App Group storage on your device and shared only with Cenzio's own widgets."
                            ),
                            PolicySection(
                                icon: "cloud",
                                tint: Color(.systemBlue),
                                title: "iCloud sync between your devices",
                                text: "Your records are copied to the private iCloud database of the iCloud account signed in on this iPhone, so your other devices with the same account stay up to date. Apple stores this data under its iCloud terms; Cenzio's developer cannot read it. Remove it in the Settings app under your name > iCloud > Manage Storage."
                            ),
                            PolicySection(
                                icon: "arrow-down-tray",
                                tint: Color(.systemTeal),
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
                                tint: Color(.systemGreen),
                                title: "No tracking or advertising",
                                text: "Cenzio does not track you across apps or websites, sell your data, show third-party ads, or include third-party analytics in the current build."
                            ),
                            PolicySection(
                                icon: "wifi",
                                tint: Color(.systemOrange),
                                title: "Sign in with Apple",
                                text: "Cenzio asks you to sign in with Apple when it opens. It keeps only Apple's anonymous user ID and, if you share them, your name and email, stored in this iPhone's Keychain. They are not sent to Cenzio's developer. Stop using your Apple ID with Cenzio in the Settings app under your name > Sign-In & Security."
                            ),
                            PolicySection(
                                icon: "trash",
                                tint: Color(.systemRed),
                                title: "Delete your app data",
                                text: "Clear All Data removes Cenzio records from this iPhone and resets app preferences. Copies already in your iCloud and on your other devices stay there, and exports you saved elsewhere are not deleted."
                            )
                        ]
                    )

                    contactCard
                    updatedLabel
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("privacy_policy".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .iOSMinimumTapTarget()
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var privacyHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                HeroIcon("hand-raised", size: 30)
                    .foregroundStyle(Color(.systemIndigo))
                    .frame(width: 58, height: 58)
                    .background(Color(.systemIndigo).opacity(0.10), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Private by default")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Your spending history stays under your control.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

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
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 24)
    }

    private var dataPath: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("How your data moves")

            VStack(spacing: 0) {
                dataPathRow(
                    icon: "document-plus",
                    tint: Color.accentColor,
                    title: "You add it",
                    detail: "Expenses, plans, categories, and preferences"
                )

                pathConnector

                dataPathRow(
                    icon: "phone",
                    tint: Color(.systemIndigo),
                    title: "Cenzio keeps it local",
                    detail: "Saved in the app's on-device storage"
                )

                pathConnector

                dataPathRow(
                    icon: "arrow-up-tray",
                    tint: Color(.systemGreen),
                    title: "You choose when it leaves",
                    detail: "Synced to your private iCloud; otherwise only through exports, support email, or consented AI drafts"
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .liquidGlassCard(cornerRadius: 22)
        }
    }

    private func policyGroup(title: String, sections: [PolicySection]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(title)

            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    policyRow(section)

                    if index < sections.count - 1 {
                        Divider()
                            .padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal, 18)
            .liquidGlassCard(cornerRadius: 22)
        }
    }

    private func policyRow(_ section: PolicySection) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HeroIcon(section.icon, size: 21)
                .foregroundStyle(section.tint)
                .frame(width: 42, height: 42)
                .background(section.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(section.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 17)
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Contact")

            VStack(alignment: .leading, spacing: 14) {
                Text("Questions about this policy or your data can be sent directly to Cenzio support. Your email and anything you include are handled by your email provider and used to respond to your request.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "mailto:umidjon.muydinov@icloud.com")!) {
                    HStack(spacing: 10) {
                        HeroIcon("envelope", size: 20)
                        Text("umidjon.muydinov@icloud.com")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        HeroIcon("arrow-right", size: 16)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 48)
                    .liquidGlassSurface(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your email app")
            }
            .padding(18)
            .liquidGlassCard(cornerRadius: 22)
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.7)
            .padding(.horizontal, 4)
    }

    private func privacyBadge(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            HeroIcon(icon, size: 15)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.systemIndigo))
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background(Color(.systemIndigo).opacity(0.08), in: Capsule())
    }

    private func dataPathRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            HeroIcon(icon, size: 20)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var pathConnector: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.34))
            .frame(width: 1, height: 10)
            .padding(.leading, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PolicySection: Identifiable {
    let icon: String
    let tint: Color
    let title: String
    let text: String

    var id: String { title }
}

#Preview {
    PrivacyPolicyView()
}
