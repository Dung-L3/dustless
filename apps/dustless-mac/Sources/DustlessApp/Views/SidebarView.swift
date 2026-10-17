import DustlessKit
import SwiftUI

enum SidebarItem: Hashable {
    case module(Module)
    case tier(TierTab)
}

struct ModuleSidebar: View {
    @ObservedObject var store: ScanStore
    let selection: Module
    let onSelect: (Module) -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List(selection: selectionBinding) {
            Section(settings.t("modules")) {
                ForEach(Module.allCases.filter { $0 != .cleanup }) { module in
                    Label(settings.t(module.titleKey), systemImage: module.symbolName)
                        .tag(SidebarItem.module(module))
                }
            }

            Section(settings.t("tiers")) {
                ForEach(TierTab.allCases) { tab in
                    tierRow(tab)
                        .tag(SidebarItem.tier(tab))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 260)
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { selection == .cleanup ? .tier(store.tierTab) : .module(selection) },
            set: { item in
                switch item {
                case .module(let module):
                    onSelect(module)
                case .tier(let tab):
                    store.tierTab = tab
                    onSelect(.cleanup)
                case .none:
                    break
                }
            }
        )
    }

    private func tierRow(_ tab: TierTab) -> some View {
        let items = store.report.map { tab.findings(in: $0) } ?? []
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let title = settings.tabTitle(tab)
        return HStack(spacing: 6) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tab.tint)
            Text(title)
                .font(PanelFont.body)
            Spacer(minLength: 4)
            Text("\(items.count)")
                .font(PanelFont.caption)
                .foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.7) : tab.tint)
            Text(ByteFormat.string(bytes))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
        }
        .frame(minHeight: PanelStyle.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(settings.t("itemMany", ["n": "\(items.count)"])) · \(ByteFormat.string(bytes))")
        .accessibilityAddTraits(store.tierTab == tab && selection == .cleanup ? [.isSelected] : [])
    }
}