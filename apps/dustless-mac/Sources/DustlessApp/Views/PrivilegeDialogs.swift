import DustlessKit
import SwiftUI

struct AwdlPrivilegeConfirm: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        content.confirmationDialog(
            settings.t("awdlInstall"),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(settings.t("awdlInstallAction"), action: onConfirm)
            Button(settings.t("confirmCancel"), role: .cancel) { isPresented = false }
        } message: {
            Text(settings.t("awdlPrivilegeExplain"))
        }
    }
}

extension View {
    func awdlPrivilegeConfirm(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(AwdlPrivilegeConfirm(isPresented: isPresented, onConfirm: onConfirm))
    }
}
