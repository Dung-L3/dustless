import DustlessKit
import SwiftUI

struct LargeFileTrashSheet: View {
    let file: LargeFile
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(Theme.Palette.warning)
                Text(settings.t("appsTrashTitle"))
                    .font(Theme.Font.title)
            }
            Text(file.name)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            PathText(path: file.path, font: Theme.Font.mono)
            Text(settings.t("largeFilesTrashBody"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.m) {
                Text(ByteFormat.string(file.size))
                    .font(Theme.Font.metric)
                Spacer()
                Button(settings.t("confirmCancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("storage.trash.cancel")
                Button(action: onConfirm) {
                    Text(settings.t("appsMoveToTrash"))
                }
                .buttonStyle(DestructiveButtonStyle())
                .accessibilityIdentifier("storage.trash.confirm")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.Palette.surface)
    }
}
