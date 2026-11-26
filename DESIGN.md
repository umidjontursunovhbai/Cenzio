---
world: night-tashkent
status: option B picked by owner (2026-11-26); plan approval pending
---

# Cenzio design system: Night Tashkent, app-wide

Source of truth for the look is onboarding v3 (`SmartSpend/Views/Onboarding/NightCityView.swift`).
This file extends it to the rest of the app. Mode: Operate (daily, one-handed logging), so native
iOS structure stays: tab bar, navigation stack, insetGrouped lists, sheets, system controls,
Dynamic Type, VoiceOver. The city and its people are the brand layer on top.

## 1. Idea

Every expense is a lit window. The city sits behind the app; small people and cars from the
onboarding street step out and stand on top of headings and buttons. They are decoration only:
never tappable, never covering text, hidden from VoiceOver.

## 2. Palette

| Token | Value | Use |
|---|---|---|
| `ink` | #05070D | dark ground, text on white buttons, light-mode figures |
| `fg` | #EEF1F6 | text, icons, avatar, dark-mode figures, primary button fill (dark) |
| `silver` | #C9D3E0 | secondary text in dark |
| `body` | #C3CBDA | long text in dark |
| `window` | #FFC878 (lit window) | city only: windows, lamps, headlight beams |
| `taxi` | #F2C230 | the taxi body only |

Rules:
- UI accent is white in dark mode and ink in light mode. No amber or gray accent on UI (owner, 2026-11-26).
- Warm light lives only inside the drawn city and figure details (window, lamp, taxi, bun, bags).
- Semantic colors stay system: sync green, systemOrange for sync problems, systemRed for delete.
- Light mode: day city (`.privacy` page), ink silhouettes, system background.

## 3. Type

- Big Shoulders Display (bundled, OFL): large titles (800), big amounts (800), section headers (600, 17 pt, sentence case).
  Use `Font.custom(_:size:relativeTo:)` so it follows Dynamic Type. Large title via
  `UINavigationBarAppearance.largeTitleTextAttributes`, so native collapse still works.
- SF Pro: everything else (rows, values, body, buttons). Buttons 17 pt semibold.
- Amounts use tabular digits.

## 4. Surfaces

- Ground: the still city, blurred 14 pt, behind lists (Settings already does this). Dark 0.8, light 0.55 opacity.
- Rows: `.ultraThinMaterial` ("white glass"), white SF Symbols, white avatar with ink initial.
- Primary button: capsule, 52 pt tall, `fg` fill with `ink` text (dark), `ink` fill with white text (light).
- Secondary button: glass capsule with white text.
- Dashboard header: a sharp (not blurred) skyline band, 150 pt. Lit windows = days of this month with at least one expense.

## 5. The street cast (small figures)

Drawn with the same code as onboarding (`person`, `taxi` in NightCityView), moved to a shared
`StreetCast` view. Height 16-20 pt (taxi 36 pt wide).

| Figure | Pose | Where it lives |
|---|---|---|
| walker | walking, plain arms | Add expense button, Settings title |
| shopper | two bags | Save button, Money header |
| snacker | eating a bun | Today header, Insights |
| taxi | yellow, headlight beam | dashboard skyline street |
| cyclist | bike | App header |
| lamp | street lamp prop, warm glow | Settings title, next to the walker |

Placement:
- A figure stands on a "kerb": the top edge of a button or the cap line of a heading's letters. Feet touch the line.
- It stands at the trailing end of the text, never over the first word, never inside a list row.
- Never on destructive buttons (Delete, Clear data), alerts, or system sheets.
- Max per screen: option A 2, option B 5.

Motion:
- One action when the screen appears: walk in about 40 pt over 1.2 s, then stop in a rest pose.
- Save button: on tap, the shopper turns and one window lights in the mini city (the onboarding promise).
- Option B only: the taxi drives across the dashboard band once per visit.
- No looping idle motion. Nothing moves on scroll.
- Reduce Motion: no entrance, figures drawn at rest; the window lights without a fade.
- Accessibility text sizes (AX1 and up): figures hidden, so they never collide with big text.

## 6. Options for the owner

- A, "Kam" (quiet): Settings title walker + lamp; dashboard skyline + walker on Add; Save shopper. Max 2 per screen.
- B, "Ko'p" (lively): A plus a figure on every Settings section header, snacker on Today, taxi pass on the dashboard. Max 5.

Decision: B everywhere (owner, 2026-11-26). Settings account row: avatar + name only, no sync line.

## 7. Implementation notes

- Extract `person`/`taxi` drawing from NightCityView into `Views/Theme/StreetCast.swift` (Canvas, no images).
- `View.kerbFigure(_:edge:)` modifier: overlay aligned to the top edge, `allowsHitTesting(false)`, `accessibilityHidden(true)`.
- `NightTheme` tokens replace `OnboardingPalette` usage outside onboarding.
- AccountView is redesigned by another session; it adopts these tokens after approval.
