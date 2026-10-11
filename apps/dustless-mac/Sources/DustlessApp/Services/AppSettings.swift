import DustlessKit
import SwiftUI

/// Light / Dark / follow-the-system. The raw values double as the i18n keys
/// (`system`, `light`, `dark`) already defined in `i18n.js`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Language + appearance, persisted in `UserDefaults` and shared as an
/// environment object. Publishing the language re-renders every view that
/// reads `t(...)`, so a switch applies without a relaunch.
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
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Key.language)
        language = stored.flatMap(Lang.init(rawValue:))
            ?? Lang.preferred(Locale.preferredLanguages.first ?? "en")
        let storedAppearance = UserDefaults.standard.string(forKey: Key.appearance)
        appearance = storedAppearance.flatMap(AppAppearance.init(rawValue:)) ?? .system
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

    /// "today" or "12d old", from the age in days, in the current language.
    func age(_ days: Double) -> String {
        days < 1 ? t("today") : t("ageDays", ["n": "\(Int(days.rounded()))"])
    }
}
