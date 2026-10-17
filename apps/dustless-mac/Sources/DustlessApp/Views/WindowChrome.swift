import DustlessKit
import SwiftUI
import AppKit

/// One visual language for the app's management windows. Memory, Storage and
/// Network each used to spell their own tokens, headers, cards and row helpers,
/// so three windows built from the same ideas drifted apart; the tokens and
/// everything shared now live here.

// MARK: - Tokens

/// Every metric the panels draw with. The Memory and Storage windows used to
/// spell their own gaps and fills, which is how two windows built from the same
/// ideas ended up looking like two products; this is the one place a value is
/// allowed to live.
enum PanelStyle {
    /// The 8pt spacing scale: 4 / 8 / 12 / 16, and nothing else. The chrome above
    /// a list is a budget, so the gaps between its sections are not free — they
    /// come from here and nowhere else.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    static let cardFill = Color.secondary.opacity(0.18)
    static let rowFill = Color.secondary.opacity(0.10)
    /// One corner radius for strips, rows and fields, so nothing reads as a card
    /// from one window and a block from another.
    static let radius: CGFloat = 8
}

/// The five sizes the panels are allowed to set. They were 12.5 / 11.5 / 13.5 and
/// whatever a view felt like at the time; a type scale only works when the
/// off-scale sizes are gone.
enum PanelFont {
    /// Panel title.
    static let title = Font.system(size: 22, weight: .semibold)
    /// 13pt: a row title, a number, a sheet heading — anything the eye lands on.
    static func emphasis(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 13, weight: weight)
    }
    /// A number that must not jitter as it updates.
    static func number(_ weight: Font.Weight = .medium) -> Font {
        .system(size: 13, weight: weight, design: .rounded).monospacedDigit()
    }
    static let body = Font.system(size: 12)
    static let secondary = Font.system(size: 11)
    static let caption = Font.system(size: 10.5)
    /// Monospaced, for paths, pids and the engine's own sentences.
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// The standard tile background: one corner radius, one fill, everywhere.
    func panelCard(_ fill: Color = PanelStyle.cardFill) -> some View {
        background(fill, in: .rect(cornerRadius: PanelStyle.radius))
    }

    /// Section label above a group of rows.
    func panelSectionHeader() -> some View {
        font(PanelFont.emphasis(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Panel skeleton

/// The frame the three management windows share: header, summary strip, filter
/// bar, then content that takes whatever height is left.
///
/// Every panel used to invent its own vertical rhythm — a divider here, a picker
/// on its own row there — and the result was chrome eating the list. The order
/// and the gaps live here instead, so "the list gets the rest" is true of all
/// three and a panel can only fill in the four bands.
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
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(.regularMaterial)
    }
}

/// The single filter row: the panel's filter control on the left, its count and
/// search field on the right.
///
/// Split across three rows it was the largest thing in the window that never told
/// the user anything — three bands of chrome for one decision. One row keeps the
/// filtering obvious (a dense screen with no visible filter is the failure mode)
/// and gives the list the height back.
struct PanelFilterBar<Filter: View, Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    @ViewBuilder let filter: () -> Filter
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: PanelStyle.Space.s) {
            filter()
            Spacer(minLength: PanelStyle.Space.s)
            trailing()
            SearchField(placeholder: placeholder, text: $text)
                .frame(maxWidth: 220)
        }
    }
}

// MARK: - Stats

/// One labelled number for the summary strip. It is a caption over a value, not a
/// card: the metric grids this replaced spent a third of the window on six tiles
/// that said the same thing in a taller box.
struct PanelStat: View {
    let label: String
    let value: String

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A row of stats that wraps instead of squeezing: six of them fit across the
/// window, and a narrow one folds to a second row instead of truncating every
/// label to nothing.
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

// MARK: - Chips

/// A coloured dot with a short label in a tinted capsule. Carries the memory
/// pressure state and each process category, so both read the same way.
struct StatusChip: View {
    let color: Color
    let text: String
    /// Tinted chips read as status; muted ones read as metadata.
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

// MARK: - Header

/// The title row every panel shares: a title, an optional secondary line, then
/// the panel's controls. There is deliberately no close button here — these are
/// `Window` scenes with the standard traffic lights, and clicking away closes
/// them (`CloseOnResignKey`).
struct PanelHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PanelFont.title)
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
    /// A title row with nothing beside it.
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Search

/// The filter field the panels share.
///
/// `.searchable` is not an option here: it only renders where a toolbar can host
/// the field (a `NavigationStack`, `NavigationSplitView` or `List`), and these
/// panels are plain `VStack`s inside bare `Window` scenes — there it silently
/// draws nothing while the view still filters, so the search looked broken.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(PanelFont.body)
                .accessibilityLabel(placeholder)

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

/// A compact bordered refresh button, used by the panels that re-read on demand.
struct RefreshButton: View {
    let isBusy: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(settings.t("refresh"))
            }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help(settings.t("refreshHelp"))
        .accessibilityLabel(settings.t("refresh"))
    }
}

// MARK: - States

/// The one loading / empty / error state used by every panel, so the Memory and
/// Storage windows cannot drift apart on how they say "still working",
/// "nothing here" and "that failed".
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
    var title: String?
    var actionTitle: String?
    var action: (() -> Void)?

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
            }
        }
        .padding(PanelStyle.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// An engine error is worth copying, so it is selectable and monospaced.
    private var messageLabel: some View {
        Text(message)
            .font(kind == .error ? PanelFont.mono(11) : PanelFont.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440)
            .modifier(OptionalTextSelection(isEnabled: kind == .error))
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

// MARK: - Path actions

/// Shared context menu for file path actions (Reveal in Finder, Copy Path).
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