import AppKit
import DustlessKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    @MainActor
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let language = "dustless.language"
        static let appearance = "dustless.appearance"
        static let showInDock = "dustless.showInDock"
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

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Key.showInDock)
            applyActivationPolicy()
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Key.language)
        language = stored.flatMap(Lang.init(rawValue:))
            ?? Lang.preferred(Locale.preferredLanguages.first ?? "en")
        let storedAppearance = UserDefaults.standard.string(forKey: Key.appearance)
        appearance = storedAppearance.flatMap(AppAppearance.init(rawValue:)) ?? .system
        showInDock = UserDefaults.standard.object(forKey: Key.showInDock) as? Bool ?? true
        applyAppearance()
        applyActivationPolicy()
    }

    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
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

    func relativeAge(since date: Date?) -> String {
        guard let date else { return t("overviewAgeNow") }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return t("overviewAgeNow") }
        if seconds < 3600 { return t("overviewAgeMinutes", ["n": "\(Int(seconds / 60))"]) }
        if seconds < 86400 { return t("overviewAgeHours", ["n": "\(Int(seconds / 3600))"]) }
        return t("overviewAgeDays", ["n": "\(Int(seconds / 86400))"])
    }

    func provenance(_ report: ScanReport?, scannedAt: Date?) -> String {
        guard let report else { return t("overviewNoScan") }
        return t("overviewProvenance", [
            "age": relativeAge(since: scannedAt),
            "rules": "\(Set(report.findings.map(\.ruleId)).count)",
            "ms": Duration.milliseconds(report.scannedMs),
        ])
    }

    func pressureLabel(_ pressure: Pressure) -> String {
        switch pressure {
        case .normal: t("pressureNormal")
        case .warn: t("pressureWarn")
        case .critical: t("pressureCritical")
        }
    }

    func age(_ days: Double) -> String {
        days < 1 ? t("today") : t("ageDays", ["n": "\(Int(days.rounded()))"])
    }
}