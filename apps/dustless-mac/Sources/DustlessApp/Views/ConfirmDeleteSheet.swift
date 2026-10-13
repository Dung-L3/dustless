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
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                Text(finding.ruleId)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                Text(finding.desc)
                                    .font(.system(size: 11))
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
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(finding.tier == .blocked ? Color.red : Color.secondary)
                                }
                            }
                            Spacer(minLength: 10)
                            Text(ByteFormat.string(finding.bytes))
                                .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(settings.t("reviewBeforeDeleting"))
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(settings.t("confirmSheetBody", ["n": "\(findings.count)"]))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Text(settings.t("totalLabel"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.t("confirmTotal", ["amount": ByteFormat.string(totalBytes)]))

            HStack(spacing: 10) {
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
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

struct ApplyResultSheet: View {
    let report: ApplyReport
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("resultTitle"))
                    .font(.system(size: 16, weight: .semibold))
                Text(settings.t("resultSummary", [
                    "freed": ByteFormat.string(report.freed),
                    "elapsed": Duration.milliseconds(report.elapsedMs),
                    "free": ByteFormat.string(report.freeAfter),
                ]))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.outcomes) { outcome in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: outcome.status))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tint(for: outcome.status))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(outcome.path)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                if !outcome.detail.isEmpty {
                                    Text(outcome.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .lineLimit(nil)
                                }
                            }
                            Spacer(minLength: 10)
                            Text(ByteFormat.string(outcome.bytes))
                                .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .pathContextMenu(outcome.path)
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(settings.t("done"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 540)
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
}
