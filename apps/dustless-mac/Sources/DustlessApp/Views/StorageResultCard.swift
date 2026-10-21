import DustlessKit
import SwiftUI

struct StorageResultCard: View {
    let report: UninstallReport
    let title: String
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.outcomes) { outcome in
                        outcomeRow(outcome)
                    }
                }
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PanelFont.emphasis(.semibold))
                Text(summaryText)
                    .font(PanelFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(summaryText)
                    .accessibilityLabel(summaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
            .accessibilityIdentifier("storage.result.close")
        }
    }

    private var summaryText: String {
        settings.t("appsResultSummary", [
            "freed": ByteFormat.string(report.summary.totalBytes),
            "count": "\(report.outcomes.count)",
        ])
    }

    private func outcomeRow(_ outcome: UninstallOutcome) -> some View {
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
                    .font(PanelFont.mono(11.5))
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
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, PanelStyle.Space.s)
        .padding(.horizontal, 2)
        .pathContextMenu(outcome.path)
        .accessibilityIdentifier("storage.outcome.\(outcome.status.rawValue).\(outcome.path)")
    }

    private func symbol(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "checkmark.circle.fill"
        case .purged: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: UninstallOutcome.Status) -> Color {
        switch status {
        case .trashed: .green
        case .purged: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private func statusKey(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "deleted"
        case .purged: "deleted"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }
}
