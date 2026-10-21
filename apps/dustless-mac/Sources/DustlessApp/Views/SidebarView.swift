import DustlessKit
import SwiftUI

enum SidebarItem: Hashable {
    case module(Module)
}

struct ModuleSidebar: View {
    @ObservedObject var store: ScanStore
    let selection: Module
    let onSelect: (Module) -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List(selection: selectionBinding) {
            Section(settings.t("modules")) {
                ForEach(Module.allCases) { module in
                    Label(settings.t(module.titleKey), systemImage: module.symbolName)
                        .accessibilityIdentifier("sidebar.module.\(module.rawValue)")
                        .tag(SidebarItem.module(module))
                }
            }

            Section(settings.t("tiers")) {
                ForEach(TierTab.allCases) { tab in
                    tierRow(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 260)
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { .module(selection) },
            set: { item in
                if case .module(let module) = item {
                    onSelect(module)
                }
            }
        )
    }

    private func tierRow(_ tab: TierTab) -> some View {
        let items = store.report.map { tab.findings(in: $0) } ?? []
        let title = settings.tabTitle(tab)
        let isActive = selection == .cleanup && store.tierTab == tab
        return Button {
            store.tierTab = tab
            onSelect(.cleanup)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tab.tint)
                Text(title)
                    .font(PanelFont.body)
                Spacer(minLength: 4)
                Text("\(items.count)")
                    .font(PanelFont.caption)
                    .foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.7) : tab.tint)
            }
            .frame(minHeight: PanelStyle.rowMinHeight)
            .contentShape(.rect)
            .background(
                isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                in: .rect(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(title): \(settings.t("itemMany", ["n": "\(items.count)"]))")
        .accessibilityIdentifier("sidebar.tier.\(tab.rawValue)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
