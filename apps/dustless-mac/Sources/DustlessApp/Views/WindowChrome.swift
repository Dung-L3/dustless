import DustlessKit
import SwiftUI
import AppKit

enum PanelStyle {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    static let cardFill = Color.secondary.opacity(0.18)
    static let rowFill = Color.secondary.opacity(0.10)
    static let radius: CGFloat = 8
    static let rowMinHeight: CGFloat = 34
    static let byteColumnWidth: CGFloat = 68
}

extension View {
    @ViewBuilder
    func axID(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

enum PanelFont {
    static let title = Font.system(size: 22, weight: .semibold)
    static let heading = Font.system(size: 16, weight: .semibold)
    static let hero = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static func emphasis(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 13, weight: weight)
    }
    static func number(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 13, weight: weight, design: .rounded).monospacedDigit()
    }
    static let body = Font.system(size: 12)
    static let secondary = Font.system(size: 11)
    static let caption = Font.system(size: 10.5)
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum PanelMotion {
    static let crossfade = 0.15
    static let fade = 0.18
    static let banner = 0.28
    static let glance = 0.12

    static func gated(_ reduceMotion: Bool, _ duration: Double) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    static func content(_ reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .identity : .opacity
    }
}

extension View {
    func panelCard(_ fill: Color = PanelStyle.cardFill) -> some View {
        background(fill, in: .rect(cornerRadius: PanelStyle.radius))
    }

    func panelSectionHeader() -> some View {
        font(PanelFont.emphasis(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct PanelScaffold<Header: View, Summary: View, Filters: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let filters: () -> Filters
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            header()
            summary()
            filters()
            content()
                .frame(maxHeight: .infinity)
        }
        .padding(PanelStyle.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelFilterBar<Filter: View, Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    @ViewBuilder let filter: () -> Filter
    @ViewBuilder let trailing: () -> Trailing
    var searchIdentifier: String? = nil

    var body: some View {
        HStack(spacing: PanelStyle.Space.s) {
            filter()
            Spacer(minLength: PanelStyle.Space.s)
            trailing()
            SearchField(placeholder: placeholder, text: $text, identifier: searchIdentifier)
                .frame(maxWidth: 280)
        }
    }
}

struct PanelStat: View {
    let label: String
    let value: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(value)
                .font(PanelFont.number())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(PanelMotion.content(reduceMotion))
                .animation(PanelMotion.gated(reduceMotion, PanelMotion.glance), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct PanelStatStrip: View {
    let stats: [(label: String, value: String)]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 88, maximum: 200), spacing: PanelStyle.Space.m)],
            alignment: .leading,
            spacing: PanelStyle.Space.s
        ) {
            ForEach(stats, id: \.label) { stat in
                PanelStat(label: stat.label, value: stat.value)
            }
        }
    }
}

struct StatusChip: View {
    let color: Color
    let text: String
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(PanelFont.secondary)
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, PanelStyle.Space.s)
        .padding(.vertical, PanelStyle.Space.xs)
        .background(color.opacity(prominent ? 0.16 : 0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct PanelHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var identifier: String?
    @ViewBuilder var accessory: Accessory

    init(title: String, subtitle: String? = nil, identifier: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.accessory = accessory()
    }

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PanelFont.title)
                    .axID(identifier)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(PanelFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: PanelStyle.Space.m)
            accessory
        }
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, identifier: String? = nil) {
        self.init(title: title, subtitle: subtitle, identifier: identifier) { EmptyView() }
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String? = nil

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(PanelFont.body)
                .help(placeholder)
                .accessibilityLabel(placeholder)
                .axID(identifier)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(settings.t("clearFilter"))
                .accessibilityLabel(settings.t("clearFilter"))
            }
        }
        .padding(.horizontal, PanelStyle.Space.s)
        .padding(.vertical, PanelStyle.Space.xs)
        .background(PanelStyle.rowFill, in: .rect(cornerRadius: PanelStyle.radius))
    }
}

struct RefreshButton: View {
    let isBusy: Bool
    let action: () -> Void
    var identifier: String? = nil

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                        .transition(.opacity)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .transition(.opacity)
                }
                Text(settings.t("refresh"))
            }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .animation(PanelMotion.gated(reduceMotion, PanelMotion.crossfade), value: isBusy)
        .help(settings.t("refreshHelp"))
        .accessibilityLabel(settings.t("refresh"))
        .axID(identifier)
    }
}

struct PanelStateView: View {
    enum Kind {
        case loading
        case empty
        case error

        var symbol: String {
            switch self {
            case .loading: "circle.dotted"
            case .empty: "tray"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    let kind: Kind
    let message: String
    var error: L10nText? = nil
    var title: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var identifier: String? = nil
    var actionIdentifier: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            if kind == .loading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(kind == .error ? Color.orange : Color.secondary)
            }

            if let title {
                Text(title)
                    .font(PanelFont.emphasis(.semibold))
            }

            messageLabel

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.large)
                    .axID(actionIdentifier)
            }
        }
        .padding(PanelStyle.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .axID(identifier)
    }

    @ViewBuilder
    private var messageLabel: some View {
        if let error {
            ScrollView {
                EngineErrorMessage(text: error)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(maxWidth: 520, maxHeight: 220)
        } else {
            Text(message)
                .font(kind == .error ? PanelFont.mono(11) : PanelFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
                .truncationMode(.tail)
                .frame(maxWidth: 440)
                .modifier(OptionalTextSelection(isEnabled: kind == .error))
                .help(message)
                .accessibilityLabel(message)
        }
    }
}

private struct OptionalTextSelection: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

struct PathContextMenu: ViewModifier {
    let path: String
    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(settings.t("revealInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button(settings.t("copyPath")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

extension View {
    func pathContextMenu(_ path: String) -> some View {
        modifier(PathContextMenu(path: path))
    }
}