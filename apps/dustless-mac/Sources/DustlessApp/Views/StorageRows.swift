import DustlessKit
import SwiftUI

struct VolumeCard: View {
    let volume: VolumeInfo
    @EnvironmentObject private var settings: AppSettings

    private static let width: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textMuted)
                Text(volume.name)
                    .font(Theme.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                Text(percentText)
                    .font(Theme.Font.number(.semibold, size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            ProgressView(value: volume.usedPercent)
                .tint(volume.usedPercent > 0.85 ? Theme.Palette.warning : Theme.Palette.accent)
                .frame(height: 3)

            Text(captionText)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .surfaceCard(padding: 0, radius: Theme.Radius.inner, tone: Theme.Palette.raised)
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

struct LargeFileRow: View {
    let file: LargeFile
    var isTrashing: Bool = false
    let onTrash: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "doc.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.Palette.textMuted)
                .frame(width: 30, height: 30)
                .background(Theme.Palette.hover, in: .rect(cornerRadius: Theme.Radius.control))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PathText(path: file.path, font: Theme.Font.caption)
            }

            Spacer(minLength: Theme.Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(file.size))
                    .font(Theme.Font.number(.semibold, size: 13))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(file.modified, format: .dateTime.year().month(.abbreviated).day())
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }

            Button(action: onTrash) {
                HStack(spacing: 5) {
                    if isTrashing {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    Text(settings.t("appsMoveToTrash"))
                }
            }
            .buttonStyle(DestructiveButtonStyle())
            .disabled(isTrashing)
            .help(settings.t("largeFilesTrashHelp", ["name": file.name]))
            .accessibilityLabel(settings.t("largeFilesTrashHelp", ["name": file.name]))
            .accessibilityIdentifier("storage.file.trash.\(file.path)")
        }
        .padding(Theme.Space.m)
        .background(hovered ? Theme.Palette.hover : Theme.Palette.raised, in: .rect(cornerRadius: Theme.Radius.inner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        }
        .onHover { hovered = $0 }
        .pathContextMenu(file.path)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.file.\(file.path)")
    }
}
