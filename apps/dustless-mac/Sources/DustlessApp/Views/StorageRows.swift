import DustlessKit
import SwiftUI

struct VolumeCard: View {
    let volume: VolumeInfo
    @EnvironmentObject private var settings: AppSettings

    private static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: PanelStyle.Space.s) {
                Text(volume.name)
                    .font(PanelFont.emphasis(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PanelStyle.Space.s)
                Text(percentText)
                    .font(PanelFont.number())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: volume.usedPercent)
                .frame(height: 3)

            Text(captionText)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.xs)
        .panelCard(PanelStyle.rowFill)
        .frame(width: Self.width)
        .help(spokenText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText)
    }

    private var percentText: String {
        volume.usedPercent.formatted(.percent.precision(.fractionLength(0)))
    }

    private var captionText: String {
        settings.t("volumeCaption", [
            "used": ByteFormat.string(volume.used),
            "free": ByteFormat.string(volume.free),
            "total": ByteFormat.string(volume.total),
        ])
    }

    private var spokenText: String {
        "\(settings.t("volumeUsageHelp", ["name": volume.name, "percent": percentText])) \(captionText)"
    }
}

struct AppRow: View {
    let app: InstalledApp
    var isUninstalling: Bool = false
    let onUninstall: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: PanelStyle.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.bundleId)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PanelStyle.Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(app.bytes))
                    .font(PanelFont.number())
                    .foregroundStyle(.primary)
                Text(settings.t("appsRelatedCount", ["n": "\(app.relatedPaths.count)"]))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsUninstall"), role: .destructive, action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isUninstalling)
                .help(settings.t("appsUninstallHelp", ["name": app.name]))
                .accessibilityLabel(settings.t("appsUninstallNamed", ["name": app.name]))
                .accessibilityIdentifier("storage.app.uninstall.\(app.bundleId)")
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .pathContextMenu(app.path)
        .accessibilityElement(children: .contain)
    }
}

struct LargeFileRow: View {
    let file: LargeFile
    var isTrashing: Bool = false
    let onTrash: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: PanelStyle.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PanelStyle.Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(file.size))
                    .font(PanelFont.number())
                    .foregroundStyle(.primary)
                Text(file.modified, format: .dateTime.year().month(.abbreviated).day())
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsMoveToTrash"), role: .destructive, action: onTrash)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTrashing)
                .help(settings.t("largeFilesTrashHelp", ["name": file.name]))
                .accessibilityLabel(settings.t("largeFilesTrashHelp", ["name": file.name]))
                .accessibilityIdentifier("storage.file.trash.\(file.path)")
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .pathContextMenu(file.path)
        .accessibilityElement(children: .contain)
    }
}

struct AppUninstallRow: View {
    let name: String
    let path: String
    let bytes: UInt64?
    let isApp: Bool

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.m) {
            Image(systemName: isApp ? "app.fill" : "doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isApp ? .blue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: isApp ? .medium : .regular))
                    .textSelection(.enabled)
                Text(path)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .accessibilityLabel(settings.t("pathA11y", ["path": path]))
            }

            Spacer(minLength: PanelStyle.Space.m)

            if let bytes {
                Text(ByteFormat.string(bytes))
                    .font(PanelFont.number())
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, PanelStyle.Space.s)
        .padding(.horizontal, PanelStyle.Space.m)
        .pathContextMenu(path)
        .accessibilityElement(children: .combine)
    }
}
