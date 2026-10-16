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
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            // A refresh that failed keeps the last numbers on screen; the banner
            // is how the user learns they are stale.
            if let error = net.loadError {
                errorLabel(error)
            }
            connection
            Divider()
            airDrop
            Divider()
            operations
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        PanelHeader(title: settings.t("networkTitle")) {
            HStack(spacing: 8) {
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

    // MARK: - Connection

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.t("networkState"))
                .panelSectionHeader()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                tile(settings.t("networkInterface"), net.report?.iface)
                tile(settings.t("networkGateway"), net.report?.gateway)
                tile(settings.t("networkDns"), dnsServers)
            }
        }
    }

    /// The DNS list the engine resolved, or nothing when it found none.
    private var dnsServers: String? {
        guard let dns = net.report?.dns, !dns.isEmpty else { return nil }
        return dns.joined(separator: ", ")
    }

    /// One tile directly on the window background, like the Memory metric grid:
    /// `—` means the engine could not tell, which is a different fact from an
    /// empty value.
    private func tile(_ label: String, _ value: String?) -> some View {
        MetricCard(label: label, value: value ?? "—")
            .padding(10)
            .panelCard()
            .help(label)
    }

    // MARK: - AirDrop

    /// The same AWDL control the menu bar and Settings drive, so a permission
    /// installed here is not invisible to them and vice versa.
    private var airDrop: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t("awdlTitle"))
                .panelSectionHeader()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "airdrop")
                    .font(.system(size: 16))
                    .foregroundStyle(net.awdl.isOn ? Color.blue : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(awdlStateText)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(settings.t("awdlNote"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                airDropControls
            }
            .padding(12)
            .panelCard()

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
        HStack(spacing: 8) {
            if net.awdl.privilegeInstalled {
                Label(settings.t("awdlInstalled"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11))
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
    }

    // MARK: - Operations

    private var operations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(settings.t("networkOps"))
                    .panelSectionHeader()

                Spacer(minLength: 0)

                Picker(settings.t("networkOps"), selection: $filter) {
                    ForEach(NetOpFilter.allCases) { option in
                        Text(settings.t(option.titleKey)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(settings.t("networkOps"))
            }

            // The field lives in the content, not in `.searchable`: this is a bare
            // `Window` scene with no toolbar to host one, so `.searchable` drew
            // nothing while still filtering — an invisible, working search.
            SearchField(placeholder: settings.t("networkSearchPrompt"), text: $query)
                .frame(maxWidth: 320)

            if let error = net.runError {
                errorLabel(error)
            }

            if visibleOps.isEmpty {
                NoMatchesView()
                    .frame(maxHeight: .infinity)
            } else {
                // The list takes whatever height is left, so the filter row above
                // never pushes the window around.
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleOps) { opRow($0) }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Text(settings.t("networkNote"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func opRow(_ op: NetOp) -> some View {
        let outcome = net.outcome(for: op)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: op.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t(op.labelKey))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(settings.t(op.helpKey))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

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
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(outcome.needsAttention ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        .disabled(running || net.isBusy)
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

    private func errorLabel(_ error: L10nText) -> some View {
        Label(settings.text(error), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}