import AppKit
import SwiftUI

enum Theme {
    enum Palette {
        static let ink = adaptive(dark: 0x0B0C0D, light: 0xF4F3EF)
        static let surface = adaptive(dark: 0x121416, light: 0xFBFAF7)
        static let raised = adaptive(dark: 0x181B1D, light: 0xFFFFFF)
        static let hover = adaptive(dark: 0x1F2326, light: 0xEFEEE9)
        static let hairline = adaptive(dark: 0x2A2E30, light: 0xDDDBD4)
        static let textPrimary = adaptive(dark: 0xF2F4F2, light: 0x1D1F1C)
        static let textSecondary = adaptive(dark: 0xA7ADA8, light: 0x626861)
        static let textMuted = adaptive(dark: 0x7E857F, light: 0x6A7069)
        static let accent = adaptive(dark: 0x8BD49C, light: 0x4F9D65)
        static let onAccent = adaptive(dark: 0x0B0C0D, light: 0x0B0C0D)
        static let accentDeep = adaptive(dark: 0x5FAF72, light: 0x3C7D4E)
        static let warning = adaptive(dark: 0xE3B25C, light: 0xA66A14)
        static let danger = adaptive(dark: 0xE06C75, light: 0xB3474F)
        static let info = adaptive(dark: 0x7EA6C9, light: 0x3D6F93)
        static let selection = accent.opacity(0.14)
        static let dangerFill = danger.opacity(0.16)
        static let warningFill = warning.opacity(0.14)
        static let accentFill = accent.opacity(0.14)
        static let infoFill = info.opacity(0.14)
        static let sheetShadow = Color.black.opacity(0.28)
        static let highlight = adaptive(dark: 0xF2F4F2, light: 0x1D1F1C).opacity(0.06)
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let page: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 16
        static let inner: CGFloat = 12
        static let row: CGFloat = 10
        static let control: CGFloat = 8
        static let pill: CGFloat = 999
    }

    enum Font {
        static let display = SwiftUI.Font.system(size: 34, weight: .semibold, design: .rounded)
        static let metric = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
        static let title = SwiftUI.Font.system(size: 24, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let small = SwiftUI.Font.system(size: 11.5, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 10.5, weight: .regular)
        static let micro = SwiftUI.Font.system(size: 10, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 11.5, weight: .regular, design: .monospaced)
        static func number(_ weight: SwiftUI.Font.Weight = .medium, size: CGFloat = 13) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
    }

    enum Size {
        static let sidebar: CGFloat = 232
        static let row: CGFloat = 44
        static let control: CGFloat = 30
        static let searchWidth: CGFloat = 280
        static let byteColumn: CGFloat = 72
        static let popover: CGFloat = 328
    }

    enum Tone {
        case accent
        case warning
        case danger
        case info
        case neutral

        var color: Color {
            switch self {
            case .accent: Palette.accent
            case .warning: Palette.warning
            case .danger: Palette.danger
            case .info: Palette.info
            case .neutral: Palette.textMuted
            }
        }

        var fill: Color {
            switch self {
            case .accent: Palette.accentFill
            case .warning: Palette.warningFill
            case .danger: Palette.dangerFill
            case .info: Palette.infoFill
            case .neutral: Palette.hover
            }
        }
    }

    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: darkMode ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct SurfaceCard: ViewModifier {
    var padding: CGFloat = Theme.Space.l
    var radius: CGFloat = Theme.Radius.card
    var tone: Color = Theme.Palette.raised

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(tone, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.Palette.highlight, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .frame(height: radius)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func surfaceCard(
        padding: CGFloat = Theme.Space.l,
        radius: CGFloat = Theme.Radius.card,
        tone: Color = Theme.Palette.raised
    ) -> some View {
        modifier(SurfaceCard(padding: padding, radius: radius, tone: tone))
    }

    func hoverSurface(_ hovered: Bool, radius: CGFloat = Theme.Radius.row) -> some View {
        background(hovered ? Theme.Palette.hover : Color.clear, in: .rect(cornerRadius: radius))
    }

    func rowHover(_ hovered: Bool) -> some View {
        background(hovered ? Theme.Palette.hover : Color.clear, in: .rect(cornerRadius: Theme.Radius.row))
    }

    func premiumShadow() -> some View {
        shadow(color: Theme.Palette.sheetShadow, radius: 24, x: 0, y: 12)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .foregroundStyle(isEnabled ? Theme.Palette.onAccent : Theme.Palette.textMuted)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(isEnabled ? Theme.Palette.accent : Theme.Palette.raised, in: .capsule)
            .overlay {
                Capsule().stroke(
                    isEnabled ? Color.white.opacity(0.18) : Theme.Palette.hairline,
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.gated(reduceMotion, Motion.control), value: configuration.isPressed)
    }
}

struct WidePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .foregroundStyle(isEnabled ? Theme.Palette.onAccent : Theme.Palette.textMuted)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(isEnabled ? Theme.Palette.accent : Theme.Palette.raised, in: .capsule)
            .overlay {
                Capsule().stroke(
                    isEnabled ? Color.white.opacity(0.18) : Theme.Palette.hairline,
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.gated(reduceMotion, Motion.control), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(Theme.Palette.raised, in: .capsule)
            .overlay {
                Capsule().stroke(Theme.Palette.hairline, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.38)
            .animation(Motion.gated(reduceMotion, Motion.control), value: configuration.isPressed)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.label)
            .foregroundStyle(Theme.Palette.danger)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(Theme.Palette.dangerFill, in: .capsule)
            .overlay {
                Capsule().stroke(Theme.Palette.danger.opacity(0.35), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.38)
            .animation(Motion.gated(reduceMotion, Motion.control), value: configuration.isPressed)
    }
}

struct PlainActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.66 : 1)
    }
}

struct StatusPill: View {
    let text: String
    var tone: Theme.Tone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            } else {
                Circle()
                    .fill(tone.color)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(Theme.Font.micro)
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.fill, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    var detail: String?
    var tone: Theme.Tone = .neutral
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(Theme.Font.metric)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
                .help("\(label): \(value)")
            if let detail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(tone == .neutral ? Theme.Palette.textMuted : tone.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: Theme.Space.m, radius: Theme.Radius.inner, tone: Theme.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(detail.map { ", \($0)" } ?? "")")
        .axID(identifier)
    }
}

struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.22).delay(Motion.stagger(index))) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

struct PathText: View {
    let path: String
    var font: Font = Theme.Font.mono
    var lineLimit: Int = 1

    var body: some View {
        Text(display)
            .font(font)
            .foregroundStyle(Theme.Palette.textMuted)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
            .pathContextMenu(path)
            .accessibilityLabel(path)
    }

    private var display: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

struct SectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.micro)
            .tracking(0.6)
            .foregroundStyle(Theme.Palette.textMuted)
    }
}
