import SwiftUI

// MARK: - Focus design language
//
// A performance-wearable look: true-black canvas, dark graphite cards, one bold condensed numeral per
// idea, tracked ALL-CAPS labels, colour reserved for meaning (recovery green / yellow / red, strain
// blue, sleep periwinkle). No brand assets — just the visual grammar.

enum FT {
    // Canvas + surfaces
    static let bg = Color(red: 0, green: 0, blue: 0)
    static let card = Color(red: 0.067, green: 0.082, blue: 0.094)        // #111518
    static let cardHi = Color(red: 0.102, green: 0.122, blue: 0.137)      // #1A1F23
    static let stroke = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.09)

    // Text
    static let text = Color.white
    static let text2 = Color(red: 0.62, green: 0.66, blue: 0.70)          // #9EA8B3
    static let text3 = Color(red: 0.38, green: 0.42, blue: 0.46)          // #616B75

    // Meaning colours
    static let green = Color(red: 0.12, green: 0.86, blue: 0.43)          // #1FDB6E
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.10)         // #FFCC1A
    static let red = Color(red: 1.00, green: 0.25, blue: 0.25)            // #FF4040
    static let strain = Color(red: 0.20, green: 0.55, blue: 1.00)         // #338CFF
    static let sleep = Color(red: 0.55, green: 0.62, blue: 1.00)          // #8C9EFF
    static let teal = Color(red: 0.20, green: 0.85, blue: 0.85)

    static func recovery(_ pct: Double?) -> Color {
        guard let pct else { return text3 }
        if pct < 34 { return red }
        if pct < 67 { return yellow }
        return green
    }

    // Type
    /// Clean SF Pro: semibold numerals with tabular digits, bold headings. No condensed widths.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    static func head(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .bold, design: .default) }
    static let body = Font.system(size: 15, weight: .regular)
    static let small = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 11, weight: .semibold)
    static let labelTracking: CGFloat = 1.6
}

// MARK: - Components

/// ALL-CAPS tracked label.
struct FTLabel: View {
    let text: String
    var color: Color = FT.text2
    init(_ text: String, color: Color = FT.text2) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(FT.label)
            .tracking(FT.labelTracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Section header row: label left, optional trailing accessory.
struct FTSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FTLabel(title)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 2)
            content()
        }
    }
}

extension FTSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = { EmptyView() }
        self.content = content
    }
}

/// Graphite card.
struct FTCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FT.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FT.stroke, lineWidth: 1))
    }
}

/// Ring dial with a condensed numeral inside and a label under it.
struct FTDial: View {
    let label: String
    let value: String
    let progress: Double?      // 0...1
    let color: Color
    var size: CGFloat = 96
    var caption: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(FT.track, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress ?? 0))))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 6)
                VStack(spacing: 0) {
                    Text(value)
                        .font(FT.number(size * 0.3))
                        .foregroundStyle(progress == nil ? FT.text3 : FT.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let caption {
                        Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(FT.text3)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: size, height: size)
            FTLabel(label, color: FT.text2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Key-statistic row: icon, name, value, change vs baseline.
struct FTStatRow: View {
    let icon: String
    let name: String
    let value: String
    var unit: String = ""
    var delta: String? = nil
    var deltaGood: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FT.text2)
                .frame(width: 30, height: 30)
                .background(FT.cardHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            FTLabel(name, color: FT.text2)
            Spacer()
            if let delta {
                Text(delta)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(deltaGood == nil ? FT.text3 : (deltaGood! ? FT.green : FT.red))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(FT.number(22)).foregroundStyle(FT.text)
                if !unit.isEmpty { Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(FT.text3) }
            }
        }
        .padding(.vertical, 8)
    }
}

/// Full-width primary action: white pill, black tracked caps.
struct FTPrimaryButtonStyle: ButtonStyle {
    var fill: Color = .white
    var foreground: Color = .black
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .tracking(1.4)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .foregroundStyle(foreground)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action: outlined pill.
struct FTSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .tracking(1.3)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .foregroundStyle(FT.text)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Activity / list row with a coloured icon tile.
struct FTActivityRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var value: String? = nil
    var valueCaption: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FT.head(15)).foregroundStyle(FT.text).lineLimit(1)
                Text(subtitle).font(FT.small).foregroundStyle(FT.text2).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let value {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(value).font(FT.number(22)).foregroundStyle(FT.text)
                    if let valueCaption { FTLabel(valueCaption, color: FT.text3) }
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(FT.text3)
        }
        .contentShape(Rectangle())
    }
}

/// Coach insight: coloured rail + bold condensed title + body.
struct FTInsight: View {
    let title: String
    let detail: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FT.head(15)).foregroundStyle(FT.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(FT.small).foregroundStyle(FT.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Zee | More" switch. Zee = the focused tab; More = the original NOOP layout. Same stored pref
/// everywhere, so flipping it anywhere flips the whole app.
struct ZeeModeSwitch: View {
    @AppStorage(FocusPrefs.focusModeKey) private var zeeMode = true
    var dark: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            segment("Zee", on: zeeMode) { zeeMode = true }
            segment("More", on: !zeeMode) { zeeMode = false }
        }
        .padding(3)
        .background(dark ? FT.card : Color.primary.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(dark ? FT.stroke : Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zee mode or More mode")
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? (dark ? Color.white : Color.primary) : Color.clear, in: Capsule())
                .foregroundStyle(on ? (dark ? Color.black : Color.zeeSystemBackground)
                                    : (dark ? FT.text2 : Color.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Dark, full-bleed page chrome for every Zee screen.
struct FTPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110)
                // Keep a readable column on wide Mac windows / iPad.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(FT.bg.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .zeeDarkNavBar()
    }
}

extension EdgeTip.Kind {
    var tint: Color {
        switch self {
        case .recover: return FT.yellow
        case .push: return FT.green
        case .sleep: return FT.sleep
        case .train: return FT.strain
        case .run: return FT.teal
        case .weight: return FT.text2
        case .info: return FT.text2
        }
    }
}

// MARK: - Cross-platform shims (iPhone + Mac)

extension Color {
    static var zeeSystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension View {
    @ViewBuilder func zeeInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func zeeDecimalKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder func zeeDarkNavBar() -> some View {
        #if os(iOS)
        self.toolbarBackground(FT.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Mac sheets have no intrinsic size; give Zee sheets a sensible window.
    @ViewBuilder func zeeSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 460, idealWidth: 500, minHeight: 640, idealHeight: 720)
        #else
        self
        #endif
    }
}
