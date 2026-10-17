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
                                        Text(finding.note)
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

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(settings.t("deleteItemsButton", [
                        "n": "\(findings.count)",
                        "size": ByteFormat.string(totalBytes),
                    ]))
                    .frame(minWidth: 190)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PanelStyle.Space.l)
        .background(.ultraThinMaterial)
    }
}

/// What the last cleanup actually did, drawn inline above the findings list.
///
/// This was a modal result sheet ending in Done, which asked for a second
/// acknowledgement nobody needed: the deletion had already happened and the
/// list behind it shows what is left. The card says the same thing without
/// blocking, and its corner × is a card affordance rather than a page exit.
///
/// Every number here is the engine's own measurement — `freed` is the delta it
/// read off the volume, `freeAfter` the volume reading afterwards. Nothing is
/// projected from the reclaimable total, and nothing here suggests the deleted
/// items can be brought back: `apply` unlinks them, and the confirmation sheet
/// says so before the click.
struct CleanupResultCard: View {
    let report: ApplyReport
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings

    /// The per-outcome rows start folded: the counts are the answer, and a
    /// report with dozens of outcomes must not push the list off screen.
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
        }
    }

    /// Reclaimed space as the engine measured it, and the volume reading it
    /// ended on. Free space is a reading, not a promise about the next scan.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("freed"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(report.freed))
                    .font(PanelFont.hero)
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
        .accessibilityLabel(settings.t("resultSummary", [
            "freed": ByteFormat.string(report.freed),
            "elapsed": Duration.milliseconds(report.elapsedMs),
            "free": ByteFormat.string(report.freeAfter),
        ]))
    }

    /// What happened to the selection, in the three words the panel already uses
    /// for those outcomes. A zero count is left visible rather than hidden: the
    /// user asked what was skipped, and "0" answers it.
    private var counts: some View {
        Text(settings.t("resultCounts", [
            "deleted": "\(report.deleted.count)",
            "skipped": "\(report.skipped.count)",
            "failed": "\(report.failed.count)",
        ]))
        .font(PanelFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Bounded like the storage card's outcome list: a big cleanup can
            // report hundreds of paths, and the list under it still has to be
            // reachable without scrolling past all of them.
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
    }

    private func outcomeRow(_ outcome: ApplyOutcome) -> some View {
        // One lookup, not one per line: the glyph and its spoken label must agree.
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
                if !outcome.detail.isEmpty {
                    Text(outcome.detail)
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

    /// The cleanup vocabulary, so this reads like the rest of the module.
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
