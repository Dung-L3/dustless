import DustlessKit
import SwiftUI

struct ConfirmDeleteSheet: View {
    let findings: [Finding]
    let totalBytes: UInt64
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(findings) { finding in
                        HStack(alignment: .top, spacing: 10) {
                            TierBadge(tier: finding.tier, compact: true)
                                .frame(width: 78, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.path)
                                    .font(PanelFont.mono(11))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                Text(finding.ruleId)
                                    .font(PanelFont.caption)
                                    .foregroundStyle(.tertiary)
                                Text(finding.desc)
                                    .font(PanelFont.secondary)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                if !finding.note.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 9))
                                        Text(ReasonText.text(finding.note, lang: settings.language))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .lineLimit(nil)
                                    }
                                    .font(PanelFont.caption)
                                    .foregroundStyle(finding.tier == .blocked ? Color.red : Color.secondary)
                                }
                            }
                            Spacer(minLength: 10)
                            Text(ByteFormat.string(finding.bytes))
                                .font(PanelFont.number())
                                .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
                        }
                        .padding(.vertical, PanelStyle.Space.s)
                        .padding(.horizontal, PanelStyle.Space.m)
                        .frame(minHeight: PanelStyle.rowMinHeight)
                        .contentShape(.rect)
                        .pathContextMenu(finding.path)
                        Divider().opacity(0.4)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(settings.t("reviewBeforeDeleting"))
                    .font(PanelFont.heading)
            }
            Text(settings.t("confirmSheetBody", ["n": "\(findings.count)"]))
                .font(PanelFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PanelStyle.Space.l)
    }

    private var footer: some View {
        VStack(spacing: PanelStyle.Space.m) {
            HStack {
                Text(settings.t("totalLabel"))
                    .font(PanelFont.emphasis())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(totalBytes))
                    .font(PanelFont.hero)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.t("confirmTotal", ["amount": ByteFormat.string(totalBytes)]))
            .accessibilityIdentifier("confirm.total")

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirm.cancel")
                Spacer()
                DestructiveButton(
                    help: settings.t("confirmSheetBody", ["n": "\(findings.count)"]),
                    hint: settings.t("confirmSheetBody", ["n": "\(findings.count)"]),
                    action: onConfirm
                ) {
                    Text(settings.t("deleteItemsButton", [
                        "n": "\(findings.count)",
                        "size": ByteFormat.string(totalBytes),
                    ]))
                    .frame(minWidth: 190)
                }
                .accessibilityIdentifier("confirm.delete")
            }

            safetyPromises
        }
        .padding(PanelStyle.Space.l)
        .background(.ultraThinMaterial)
    }

    private var safetyPromises: some View {
        VStack(alignment: .leading, spacing: 3) {
            promise("safetyReadOnly")
            promise("safetyRed")
            promise("safetyMeasured")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func promise(_ key: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(settings.t(key))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CleanupResultCard: View {
    let report: ApplyReport
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            header
            headline
            counts
            disclosure
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Text(settings.t("resultTitle"))
                .font(PanelFont.emphasis(.semibold))
            Spacer(minLength: PanelStyle.Space.s)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
            .accessibilityIdentifier("cleanup.result.close")
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("deleted"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(report.deletedBytes))
                    .font(PanelFont.hero)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("freed"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(report.freed))
                    .font(PanelFont.number())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("freeNow"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(report.freeAfter))
                    .font(PanelFont.number())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Text(settings.t("elapsed", ["s": Duration.milliseconds(report.elapsedMs)]))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            settings.t("resultSummary", [
                "freed": ByteFormat.string(report.freed),
                "elapsed": Duration.milliseconds(report.elapsedMs),
                "free": ByteFormat.string(report.freeAfter),
            ]) + " · " + settings.t("deleted") + " " + ByteFormat.string(report.deletedBytes)
        )
    }

    private var counts: some View {
        Text(settings.t("resultCounts", [
            "deleted": "\(report.deleted.count)",
            "skipped": "\(report.skipped.count)",
            "failed": "\(report.failed.count)",
        ]))
        .font(PanelFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("cleanup.result.counts")
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.outcomes) { outcome in
                        outcomeRow(outcome)
                    }
                }
            }
            .frame(maxHeight: 160)
        } label: {
            Text(settings.t("itemMany", ["n": "\(report.outcomes.count)"]))
                .font(PanelFont.secondary)
        }
        .accessibilityIdentifier("cleanup.result.disclosure")
    }

    private func outcomeRow(_ outcome: ApplyOutcome) -> some View {
        let status = settings.t(statusKey(for: outcome.status))
        return HStack(alignment: .top, spacing: PanelStyle.Space.m) {
            Image(systemName: symbol(for: outcome.status))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint(for: outcome.status))
                .frame(width: 14)
                .help(settings.t("outcomeStatus", ["status": status]))
                .accessibilityLabel(settings.t("outcomeStatus", ["status": status]))
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.path)
                    .font(PanelFont.mono(11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                if let detail = outcome.detail {
                    Text(ReasonText.text(detail, lang: settings.language))
                        .font(PanelFont.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                }
            }
            Spacer(minLength: PanelStyle.Space.m)
            Text(ByteFormat.string(outcome.bytes))
                .font(PanelFont.number())
                .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, PanelStyle.Space.xs)
        .padding(.horizontal, 2)
        .frame(minHeight: PanelStyle.rowMinHeight)
        .pathContextMenu(outcome.path)
    }

    private func symbol(for status: ApplyStatus) -> String {
        switch status {
        case .deleted: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: ApplyStatus) -> Color {
        switch status {
        case .deleted: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private func statusKey(for status: ApplyStatus) -> String {
        switch status {
        case .deleted: "deleted"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }
}

private extension ApplyReport {
    var skipped: [ApplyOutcome] { outcomes.filter { $0.status == .skipped } }
    var failed: [ApplyOutcome] { outcomes.filter { $0.status == .failed } }
}