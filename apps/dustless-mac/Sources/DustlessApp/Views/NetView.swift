import DustlessKit
import SwiftUI
import AppKit

/// Which operations the list shows. Advanced ones change live network state, so
/// they get their own tab instead of sitting mixed in with the safe flush.
enum NetOpFilter: String, CaseIterable, Identifiable {
    case all
    case safe
    case advanced

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: "networkFilterAll"
        case .safe: "networkFilterSafe"
        case .advanced: "networkFilterAdvanced"
        }
    }

    func matches(_ op: NetOp) -> Bool {
        switch self {
        case .all: true
        case .safe: !op.isAdvanced
        case .advanced: op.isAdvanced
        }
    }
}

struct NetView: View {
    @ObservedObject var net: NetControl
    @EnvironmentObject private var settings: AppSettings

    @State private var query = ""
    @State private var filter: NetOpFilter = .all

    var body: some View {
        PanelScaffold {
            header
        } summary: {
            summary
        } filters: {
            filterBar
        } content: {
            operations
        }
    }

    // MARK: - Header

    private var header: some View {
        PanelHeader(title: settings.t("networkTitle")) {
            HStack(spacing: PanelStyle.Space.s) {
                // Worth saying out loud: this is why the engine refuses the
                // interface operations unless the run is forced.
                if net.report?.soloRoute == true {
                    StatusChip(color: .orange, text: settings.t("networkSoloRoute"))
                }
                RefreshButton(isBusy: net.isLoading) {
                    Task { await net.refresh() }
                }
            }
        }
    }

    // MARK: - Summary

    /// Connection numbers as one row of stats, plus the AirDrop block that shares
    /// the band. The three tiles this replaced were three cards for three strings,
    /// and a gateway address is not 40pt of information.
    private var summary: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            // A refresh that failed keeps the last numbers on screen; the banner
            // is how the user learns they are stale. Capped for the same reason
            // as the AirDrop sentence below: this band does not scroll, and an
            // engine error carries whatever stderr the process printed, which is
            // not a bounded amount of text.
            if let error = net.loadError {
                errorLabel(error)
            }

            connection
            airDrop
        }
    }

    private var connection: some View {
        HStack(spacing: PanelStyle.Space.m) {
            connectionStat(settings.t("networkInterface"), net.report?.iface)
            connectionStat(settings.t("networkGateway"), net.report?.gateway)
            connectionStat(settings.t("networkDns"), dnsServers)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("networkState"))
    }

    /// The DNS list the engine resolved, or nothing when it found none.
    private var dnsServers: String? {
        guard let dns = net.report?.dns, !dns.isEmpty else { return nil }
        return dns.joined(separator: ", ")
    }

    /// `—` means the engine could not tell, which is a different fact from an
    /// empty value. Addresses are long, so the value truncates in the middle and
    /// the full string stays in the tooltip.
    private func connectionStat(_ label: String, _ value: String?) -> some View {
        PanelStat(label: label, value: value ?? "—")
            .truncationMode(.middle)
            .help(value ?? label)
    }

    // MARK: - AirDrop

    /// The same AWDL control the menu bar and Settings drive, so a permission
    /// installed here is not invisible to them and vice versa.
    private var airDrop: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("awdlTitle"))
                .panelSectionHeader()

            HStack(alignment: .top, spacing: PanelStyle.Space.m) {
                Image(systemName: "airdrop")
                    .font(.system(size: 16))
                    .foregroundStyle(net.awdl.isOn ? Color.blue : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(awdlStateText)
                        .font(PanelFont.emphasis())
                    // Two lines, then stop. This block sits in the summary band,
                    // which does not scroll, and this sentence is ~200 characters in
                    // every language: unbounded it takes whatever height it wants and
                    // the list below pays. Measured at the smallest pane the window
                    // allows, that cost the list 39pt — about one operation row.
                    //
                    // The full sentence goes to the hover and to VoiceOver, so the cap
                    // costs no information: `.help` alone would not, because a
                    // truncated `Text` labels itself with the truncated string.
                    Text(settings.t("awdlNote"))
                        .font(PanelFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(settings.t("awdlNote"))
                        .accessibilityLabel(settings.t("awdlNote"))
                }

                Spacer(minLength: PanelStyle.Space.s)

                airDropControls
            }
            .padding(PanelStyle.Space.m)
            .panelCard()

            // The same band as the sentence above, so the same cap: this is
            // also engine stderr, and an uncapped one took another 50pt out of
            // the operation list.
            if let error = net.awdl.error {
                errorLabel(error)
            }
        }
    }

    private var awdlStateText: String {
        switch net.awdl.state {
        case .on: settings.t("awdlOn")
        case .off: settings.t("awdlOff")
        default: settings.t("awdlUnknown")
        }
    }

    /// The install step is a button, not a note: without the scoped sudo rule the
    /// toggle is refused by the engine, and the user is the one who can approve
    /// it. Once installed it turns into the fact it now is.
    @ViewBuilder
    private var airDropControls: some View {
        HStack(spacing: PanelStyle.Space.s) {
            if net.awdl.privilegeInstalled {
                Label(settings.t("awdlInstalled"), systemImage: "checkmark.seal.fill")
                    .font(PanelFont.secondary)
                    .foregroundStyle(.secondary)
                    .help(settings.t("awdlInstalled"))
            } else {
                Button(settings.t("awdlInstall")) {
                    Task { await net.awdl.installPrivilege() }
                }
                .controlSize(.small)
                .disabled(net.awdl.busy)
                .help(settings.t("awdlInstall"))
                .accessibilityLabel(settings.t("awdlInstall"))
            }

            let turningOn = !net.awdl.isOn
            Button(turningOn ? settings.t("awdlTurnOn") : settings.t("awdlTurnOff")) {
                Task { await net.setAirDrop(turningOn) }
            }
            .controlSize(.small)
            // An absent radio cannot be toggled; the engine would refuse it and
            // the button would look broken.
            .disabled(net.awdl.busy || net.awdl.state == nil || net.awdl.state == .absent)
            .help(turningOn ? settings.t("awdlTurnOn") : settings.t("awdlTurnOff"))
            .accessibilityLabel(turningOn ? settings.t("awdlTurnOn") : settings.t("awdlTurnOff"))
        }
        // The controls keep their intrinsic width; a narrow pane is paid for by
        // the sentence beside them truncating. A button that loses its label to
        // the layout is a control the user cannot read.
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Operations

    /// Which operations, and how to find one: one row. It was the section heading
    /// with a picker in it, then a search field of its own on the line below.
    private var filterBar: some View {
        PanelFilterBar(placeholder: settings.t("networkSearchPrompt"), text: $query) {
            Picker(settings.t("networkOps"), selection: $filter) {
                ForEach(NetOpFilter.allCases) { option in
                    Text(settings.t(option.titleKey)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(settings.t("networkOps"))
        } trailing: {
            EmptyView()
        }
    }

    /// The list, plus the two sentences that are not the list's business.
    ///
    /// Everything in here is *capped*, and that is the whole vertical budget: an
    /// uncapped `fixedSize` paragraph cannot be compressed, so in this column it
    /// holds its lines against the one flexible child and the list pays. Pushing
    /// these into the scroll instead only hides that — it put the note a scroll
    /// away, and at the smallest pane the window allows its first two points were
    /// in the viewport and its other 24 were not. Pinned and capped costs the list
    /// 34pt, under three quarters of one of its five rows.
    private var operations: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            // One quiet line, not a card: this is a permission the advanced rows
            // below depend on, and the user is the only one who can grant it.
            rememberRow

            runErrors

            // A filter that matches nothing is not an error, so it keeps its own
            // state and says so, rather than becoming an empty scroll view.
            if visibleOps.isEmpty {
                NoMatchesView()
                    .frame(minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelStyle.Space.s) {
                        ForEach(visibleOps) { opRow($0) }
                    }
                }
                // The list takes whatever height the bands above did not, which
                // is what this says. No `layoutPriority`: see `PanelScaffold`.
                .frame(maxHeight: .infinity)
            }

            // The closing disclaimer, under the list it is about. Capped, and the
            // full sentence goes to the hover and to VoiceOver either way.
            Text(settings.t("networkNote"))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(settings.t("networkNote"))
                .accessibilityLabel(settings.t("networkNote"))
        }
    }

    /// The two failures a run can report that are not about a single
    /// row: the operation never started, or the permission it needed was missing.
    /// Pinned above the list and capped with everything else — an error that
    /// scrolls out of sight is not reported. Both are dismissible: these bands
    /// cost the list a row each, and the control that produced them is right
    /// underneath.
    @ViewBuilder
    private var runErrors: some View {
        if let error = net.runError {
            errorLabel(error) { net.dismissRunError() }
        }

        if let error = net.privilegeError {
            errorLabel(error) { net.dismissPrivilegeError() }
        }
    }

    /// The one-time authorization step, as a single line: a button while it is
    /// missing, a muted fact with a way back once it is in place. No card — this
    /// is a footnote to the operation list, and it says plainly that no password
    /// is being kept.
    @ViewBuilder
    private var rememberRow: some View {
        HStack(spacing: PanelStyle.Space.s) {
            if net.privilegeInstalled {
                Label(settings.t("netRemembered"), systemImage: "checkmark.seal")
                    .font(PanelFont.secondary)
                    .foregroundStyle(.secondary)
                    .help(settings.t("netRememberExplain"))
                    .accessibilityLabel(settings.t("netRemembered"))
                Spacer(minLength: PanelStyle.Space.s)
                Button(settings.t("netForget")) {
                    Task { await net.removePrivilege() }
                }
                .controlSize(.small)
                .disabled(net.privilegeBusy)
                .help(settings.t("netForget"))
                .accessibilityLabel(settings.t("netForget"))
            } else {
                Button(settings.t("netRemember")) {
                    Task { await net.installPrivilege() }
                }
                .controlSize(.small)
                .disabled(net.privilegeBusy)
                .help(settings.t("netRememberExplain"))
                .accessibilityLabel(settings.t("netRemember"))
                Text(settings.t("netRememberExplain"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PanelStyle.Space.s)
    }

    private func opRow(_ op: NetOp) -> some View {
        let outcome = net.outcome(for: op)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: op.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t(op.labelKey))
                        .font(PanelFont.emphasis(.semibold))
                    Text(settings.t(op.helpKey))
                        .font(PanelFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: PanelStyle.Space.s)

                if op.isAdvanced {
                    StatusChip(color: .orange, text: settings.t("networkNeedsAdmin"))
                }

                if let outcome {
                    statusGlyph(outcome)
                }

                runButton(op)
            }

            if let outcome, !outcome.detail.isEmpty {
                // The engine's own sentence, verbatim: when it explains a refusal,
                // its wording beats anything the UI could paraphrase it with.
                Text(outcome.detail)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(outcome.needsAttention ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func runButton(_ op: NetOp) -> some View {
        let running = net.isRunning(op)
        Button {
            Task { await net.run(op) }
        } label: {
            if running {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 11, height: 11)
                    Text(settings.t("networkRunning"))
                }
            } else {
                Text(settings.t("networkRun"))
            }
        }
        .controlSize(.small)
        // `privilegeBusy` too: that flag is the install or remove admin prompt,
        // which no operation is waiting on but which the user cannot answer
        // while a second SecurityAgent dialog is stacked on top of it.
        .disabled(running || net.isBusy || net.privilegeBusy)
        .help(settings.t(op.helpKey))
        .accessibilityLabel(settings.t("networkRunNamed", ["name": settings.t(op.labelKey)]))
    }

    @ViewBuilder
    private func statusGlyph(_ outcome: NetOutcome) -> some View {
        let (symbol, tint) = Self.outcomeAppearance(outcome.status)
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .help(outcome.detail)
            .accessibilityLabel(outcome.detail)
    }

    /// A refusal is the engine saying no on purpose; only a failure is an error,
    /// and a skip is a decision, not a problem.
    private static func outcomeAppearance(_ status: NetOutcomeStatus) -> (symbol: String, tint: Color) {
        switch status {
        case .ran: ("checkmark.circle.fill", .green)
        case .refused: ("hand.raised.fill", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        case .skipped, .notApplicable: ("minus.circle", .secondary)
        }
    }

    // MARK: - Filtering

    private var visibleOps: [NetOp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return NetOp.allCases.filter { op in
            filter.matches(op) && (needle.isEmpty || matches(needle, op))
        }
    }

    /// Label or wire id: a user remembers either, and the id is what the engine
    /// prints, so both have to be findable.
    private func matches(_ needle: String, _ op: NetOp) -> Bool {
        settings.t(op.labelKey).lowercased().contains(needle) || op.id.contains(needle)
    }

    /// The engine's own sentence about a failure, verbatim: when it explains a
    /// refusal, its wording beats anything the UI could paraphrase it with.
    ///
    /// Capped at two lines, because every call site is a non-scrolling band and
    /// engine stderr is not a bounded amount of text. Uncapped, the refresh
    /// banner and the AirDrop error alone cost the operation list 77pt — three
    /// of its five rows — at the smallest pane the window allows. The full
    /// sentence goes to the hover and to VoiceOver either way, so the cap costs
    /// no information; `.help` alone would not, because a truncated `Text`
    /// labels itself with the truncated string.
    ///
    /// `onDismiss` draws the card's corner × — the same affordance the result
    /// cards use — so a banner that has been answered can be taken down without
    /// running anything else. It is omitted for the two callers that own a
    /// control which clears the message itself.
    private func errorLabel(_ error: L10nText, onDismiss: (() -> Void)? = nil) -> some View {
        let text = settings.text(error)
        let label = Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(PanelFont.mono(11))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(text)
            .accessibilityLabel(text)
        return HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            label
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(settings.t("close"))
                .accessibilityLabel(settings.t("close"))
            }
        }
    }
}
