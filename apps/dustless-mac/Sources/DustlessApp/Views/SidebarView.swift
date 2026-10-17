import DustlessKit
import SwiftUI

/// What a sidebar row points at. Cleanup's tier rows are not modules — they
/// pick which tier the Cleanup module shows — so they need their own selection
/// identity or the highlighted row could not follow `store.tierTab`.
enum SidebarItem: Hashable {
    case module(Module)
    case tier(TierTab)
}

/// The one navigation. Modules first, then the safety tiers of the Cleanup
/// module — which is why the tier rows stay the only rows that carry live
/// counts: they are the answer to "what is there to clean", and the byte
/// numbers change under the user's cursor as a rescan lands.
struct ModuleSidebar: View {
    @ObservedObject var store: ScanStore
    /// The router's module. Derived into the List's selection below rather than
    /// stored here: one value is the truth, and the sidebar is its view.
    let selection: Module
    let onSelect: (Module) -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List(selection: selectionBinding) {
            Section(settings.t("modules")) {
                // Cleanup has a section of its own below, so it is not repeated
                // here as a bare module row.
                ForEach(Module.allCases.filter { $0 != .cleanup }) { module in
                    Label(settings.t(module.titleKey), systemImage: module.symbolName)
                        .tag(SidebarItem.module(module))
                }
            }

            // Always present, even with nothing scanned: this is how the user
            // reaches the Cleanup module and the scan button inside it.
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
                // Fixed, so a count that grows a digit does not shove the size
                // sideways while the user is reading it.
                .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
        }
        .frame(minHeight: PanelStyle.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(settings.t("itemMany", ["n": "\(items.count)"])) · \(ByteFormat.string(bytes))")
        .accessibilityAddTraits(store.tierTab == tab && selection == .cleanup ? [.isSelected] : [])
    }
}
