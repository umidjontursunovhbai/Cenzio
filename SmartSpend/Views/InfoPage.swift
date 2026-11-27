import SwiftUI

/// A pushed info page (Import guide, Budget goals info): flat night ground, a large
/// Big Shoulders title that collapses on scroll, a lead line and glass sections.
/// The pushing stack gives the back button; there is no close button.
struct InfoPage<Content: View>: View {
    let title: String
    let lead: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(lead)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(NightGround())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .tint(NightTheme.accent)
    }
}

/// Section of an info page: a Big Shoulders heading, an optional note, then its content.
struct InfoPageSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NightTheme.display(21, weight: .semibold, relativeTo: .title3))
                    .accessibilityAddTraits(.isHeader)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// Glass group of icon + text rows split by hairlines.
struct InfoPageList: View {
    let rows: [(icon: String, text: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().overlay(NightTheme.hair).padding(.leading, 56)
                }
                HStack(alignment: .top, spacing: 12) {
                    HeroIcon(row.icon, size: 17)
                        .foregroundStyle(NightTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text(row.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .nightGroup()
    }
}

/// A CSV line as it appears in the file.
struct InfoPageCode: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
