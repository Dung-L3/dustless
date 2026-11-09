import DustlessKit
import SwiftUI

struct ModuleSidebar: View {
    let selection: Module
    let onSelect: (Module) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var activePill

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(ModuleGroup.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            SectionEyebrow(text: settings.t(group.titleKey))
                                .padding(.horizontal, 10)
                            ForEach(Module.allCases.filter { $0.group == group }) { module in
                                SidebarRow(
                                    module: module,
                                    title: settings.t(module.titleKey),
                                    isActive: selection == module,
                                    namespace: activePill
                                ) {
                                    onSelect(module)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.Space.l)
            }
            .scrollIndicators(.never)

            Divider()
                .overlay(Theme.Palette.hairline)

            Button {
                openSettings()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18)
                    Text(settings.t("settingsOpen"))
                        .font(Theme.Font.label)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.settings")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: Theme.Size.sidebar)
        .background(Theme.Palette.ink)
        .animation(Motion.gated(reduceMotion, Motion.control), value: selection)
    }
}

private struct SidebarRow: View {
    let module: Module
    let title: String
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .frame(width: 18)
                Text(title)
                    .font(Theme.Font.label)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(.rect)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.Palette.selection)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.Palette.accent)
                                .frame(width: 2, height: 16)
                                .padding(.leading, 4)
                        }
                        .matchedGeometryEffect(id: "sidebar.active", in: namespace)
                } else if hovered {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.Palette.hover)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar.module.\(module.rawValue)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
