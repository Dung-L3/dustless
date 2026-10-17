import AppKit
import DustlessKit
import SwiftUI

/// Light / Dark / follow-the-system. The raw values double as the i18n keys
/// (`system`, `light`, `dark`) already defined in the string tables.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The AppKit appearance this mode means. `nil` = follow the system.
    ///
    /// An `NSAppearance`, not a SwiftUI `ColorScheme`, on purpose.
    /// `.preferredColorScheme` does follow a live change and does release cleanly
    /// when handed back `nil` — but it pins the choice on each *scene's* window,
    /// so it never reaches a surface that is not inside a scene. The menu-bar
    /// popover is AppKit's, drawn outside every SwiftUI scene, and that is the one
    /// piece of the app that stayed on the system scheme while the window went
    /// dark. `NSApp.appearance` is the single value every window, every sheet and
    /// every AppKit-drawn control reads, and `nil` is the documented way to hand
    /// the app back to the system.
    ///
    /// Measured, with the window already open and the setting flipped at runtime:
    /// under `NSApp.appearance` the main window and the settings window both report
    /// `appearance == nil` and an `effectiveAppearance` equal to the app's choice —
    /// they *inherit* it instead of being pinned, so a window or sheet created
    /// after the switch is already correct without anything re-applying it.
    @MainActor
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Language + appearance, persisted in `UserDefaults` and shared as an
/// environment object. Publishing the language re-renders every view that
/// reads `t(...)`, so a switch applies without a relaunch; publishing the
/// appearance pushes it onto the app, see `applyAppearance()`.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "dustless.language"
        static let appearance = "dustless.appearance"
    }

    @Published var language: Lang {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Key.language) }
    }

    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Key.language)
        language = stored.flatMap(Lang.init(rawValue:))
            ?? Lang.preferred(Locale.preferredLanguages.first ?? "en")
        let storedAppearance = UserDefaults.standard.string(forKey: Key.appearance)
        appearance = storedAppearance.flatMap(AppAppearance.init(rawValue:)) ?? .system
        // Before any window exists, so a stored Dark does not open the app in the
        // system's appearance for a frame — and so it is not a promise Settings
        // makes that the app only keeps until the next launch.
        applyAppearance()
    }

    /// Push the current appearance onto the app, for every scene at once.
    ///
    /// Called from `init` and from the setter, and safe to call again: it only
    /// writes the value that is set, so the app converges on the choice in
    /// `AppSettings` instead of on whatever the last writer left behind.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        L10n.render(language, key, vars)
    }

    func text(_ text: L10nText?) -> String {
        text.map { L10n.text(language, $0) } ?? ""
    }

    func tierLabel(_ tier: Tier) -> String {
        L10n.render(language, L10n.tierKey(tier))
    }

    func tierExplanation(_ tier: Tier) -> String {
        L10n.render(language, "\(L10n.tierKey(tier))Hint")
    }

    func tabTitle(_ tab: TierTab) -> String {
        L10n.render(language, tab.titleKey)
    }

    func tabEmpty(_ tab: TierTab) -> String {
        L10n.render(language, tab.emptyKey)
    }

    /// "just now" / "5 min ago" / "2 h ago" / "3 d ago", from the moment a report
    /// landed. Shared by the dashboard's provenance line and the menu-bar popover
    /// so the two surfaces cannot age the same report differently.
    ///
    /// It does not tick on its own: a label that silently grows stale is a lie in
    /// the other direction, and the next scan redraws it anyway.
    func relativeAge(since date: Date?) -> String {
        guard let date else { return t("overviewAgeNow") }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return t("overviewAgeNow") }
        if seconds < 3600 { return t("overviewAgeMinutes", ["n": "\(Int(seconds / 60))"]) }
        if seconds < 86400 { return t("overviewAgeHours", ["n": "\(Int(seconds / 3600))"]) }
        return t("overviewAgeDays", ["n": "\(Int(seconds / 86400))"])
    }

    /// Where the numbers on screen came from, in one line: how long ago the scan
    /// ran, how many rules produced findings, how long it took. The rule count is
    /// derived from the report rather than a hard-coded list, so a rule that found
    /// nothing never reaches the user as a claim.
    func provenance(_ report: ScanReport?, scannedAt: Date?) -> String {
        guard let report else { return t("overviewNoScan") }
        return t("overviewProvenance", [
            "age": relativeAge(since: scannedAt),
            "rules": "\(Set(report.findings.map(\.ruleId)).count)",
            "ms": Duration.milliseconds(report.scannedMs),
        ])
    }

    /// The memory pressure word the engine reported. Both the dashboard and the
    /// menu-bar popover print it, so the mapping lives once.
    func pressureLabel(_ pressure: Pressure) -> String {
        switch pressure {
        case .normal: t("pressureNormal")
        case .warn: t("pressureWarn")
        case .critical: t("pressureCritical")
        }
    }

    /// "today" or "12d old", from the age in days, in the current language.
    func age(_ days: Double) -> String {
        days < 1 ? t("today") : t("ageDays", ["n": "\(Int(days.rounded()))"])
    }
}
