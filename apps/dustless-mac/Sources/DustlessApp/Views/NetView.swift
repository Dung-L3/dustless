import DustlessKit
import SwiftUI
import AppKit

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

    private var header: some View {
        PanelHeader(title: settings.t("networkTitle")) {
            HStack(spacing: PanelStyle.Space.s) {
                if net.report?.soloRoute == true {
                    StatusChip(color: .orange, text: settings.t("networkSoloRoute"))
                }
                RefreshButton(isBusy: net.isLoading) {
                    Task { await net.refresh() }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
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

    private var dnsServers: String? {
        guard let dns = net.report?.dns, !dns.isEmpty else { return nil }
        return dns.joined(separator: ", ")
    }

    private func connectionStat(_ label: String, _ value: String?) -> some View {
        PanelStat(label: label, value: value ?? "—")
            .truncationMode(.middle)
            .help(value ?? label)
    }

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
            .disabled(net.awdl.busy || net.awdl.state == nil || net.awdl.state == .absent)
            .help(turningOn ? settings.t("awdlTurnOn") : settings.t("awdlTurnOff"))
            .accessibilityLabel(turningOn ? settings.t("awdlTurnOn") : settings.t("awdlTurnOff"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

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

    private var operations: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            rememberRow

            runErrors

            if visibleOps.isEmpty {
                NoMatchesView()
                    .frame(minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelStyle.Space.s) {
                        ForEach(visibleOps) { opRow($0) }
                    }
                }
                .frame(maxHeight: .infinity)
            }

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

    @ViewBuilder
    private var runErrors: some View {
        if let error = net.runError {
            errorLabel(error) { net.dismissRunError() }
        }

        if let error = net.privilegeError {
            errorLabel(error) { net.dismissPrivilegeError() }
        }
    }

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

    private static func outcomeAppearance(_ status: NetOutcomeStatus) -> (symbol: String, tint: Color) {
        switch status {
        case .ran: ("checkmark.circle.fill", .green)
        case .refused: ("hand.raised.fill", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        case .skipped, .notApplicable: ("minus.circle", .secondary)
        }
    }

    private var visibleOps: [NetOp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return NetOp.allCases.filter { op in
            filter.matches(op) && (needle.isEmpty || matches(needle, op))
        }
    }

    private func matches(_ needle: String, _ op: NetOp) -> Bool {
        settings.t(op.labelKey).lowercased().contains(needle) || op.id.contains(needle)
    }

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