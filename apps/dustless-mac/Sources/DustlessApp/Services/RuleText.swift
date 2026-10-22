import DustlessKit

enum RuleText {
    static func description(ruleId: String, engineDescription: String, lang: Lang) -> String {
        let key = "rule.\(ruleId)"
        if L10n.table(.en)[key] != nil {
            return L10n.render(lang, key)
        }
        let trimmed = engineDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.render(lang, "ruleCustom") : trimmed
    }

    static func description(of finding: Finding, lang: Lang) -> String {
        description(ruleId: finding.ruleId, engineDescription: finding.desc, lang: lang)
    }
}
