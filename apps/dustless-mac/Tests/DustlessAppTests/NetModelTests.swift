import Testing
import Foundation
import DustlessKit
@Suite("network model")
struct NetModelTests {
    @Test func decodesAReportWithAnOutcome() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: fixture("net.json"))
        #expect(report.platform == "mac")
        #expect(report.iface == "en0")
        #expect(report.gateway == "192.168.1.1")
        #expect(report.dns == ["1.1.1.1", "1.0.0.1", "8.8.8.8"])
        #expect(report.soloRoute)
        let outcome = try #require(report.outcome(for: "reset-dns"))
        #expect(outcome.status == .ran)
        #expect(outcome.before == "1.1.1.1, 1.0.0.1")
        #expect(outcome.after == "DHCP-provided values")
        #expect(outcome.needsAttention == false)
    }

    @Test func decodesAReadOnlyReportWithNoRoute() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"linux","iface":null,"gateway":null,"dns":[],"soloRoute":false,"outcomes":[]}
        """#.utf8))
        #expect(report.iface == nil)
        #expect(report.gateway == nil)
        #expect(report.outcomes.isEmpty)
        #expect(report.outcome(for: "flush-dns") == nil)
    }

    @Test func notApplicableKeepsItsHyphenatedWireValue() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"mac","iface":"en0","gateway":"1.1.1.1","dns":[],"soloRoute":true,"outcomes":[{"op":"flush-routing","status":"not-applicable","detail":"no route cache"}]}
        """#.utf8))
        #expect(report.outcomes.first?.status == .notApplicable)
    }

    @Test func aRefusalIsNotAFailure() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"mac","iface":"en0","gateway":"1.1.1.1","dns":[],"soloRoute":true,"outcomes":[{"op":"renew-dhcp","status":"refused","detail":"needs root"}]}
        """#.utf8))
        #expect(report.outcomes.first?.needsAttention == true)
    }

    @Test func anUnknownStatusThrowsRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NetReport.self, from: Data(#"""
            {"platform":"mac","iface":null,"gateway":null,"dns":[],"soloRoute":true,"outcomes":[{"op":"x","status":"maybe","detail":""}]}
            """#.utf8))
        }
    }

    @Test func everyOfferedOperationIsTranslatedInEveryLanguage() {
        for op in NetOp.allCases {
            for lang in Lang.allCases {
                let table = L10n.table(lang)
                #expect(table[op.labelKey] != nil, "\(lang)/\(op.labelKey)")
                #expect(table[op.helpKey] != nil, "\(lang)/\(op.helpKey)")
            }
        }
    }

    @Test func theOfferedSetMatchesTheEngine() {
        #expect(NetOp(rawValue: "flush-routing") == nil)
        #expect(NetOp.allCases.count == 5)
        #expect(NetOp.flushDns.isAdvanced == false)
        #expect(NetOp.allCases.filter(\.isAdvanced).count == NetOp.allCases.count - 1)
        #expect(NetOp.resetDns.flag == "--reset-dns")
        #expect(NetOp.renewDhcp.flag == "--renew-dhcp")
    }

    @Test func thePrivilegeRuleIsScopedToFourExactCommands() throws {
        let privilege = try JSONDecoder().decode(NetPrivilege.self, from: fixture("net-privilege.json"))
        #expect(privilege.path == "/etc/sudoers.d/dustless-net")
        #expect(privilege.user == "mac")
        #expect(privilege.allowed.count == 4)
        for command in privilege.allowed {
            #expect(command.hasPrefix("/usr/sbin/") || command.hasPrefix("/sbin/"))
        }
        #expect(privilege.rule.contains("NOPASSWD:"))
        #expect(!privilege.rule.contains("*"))
        for command in privilege.allowed {
            #expect(privilege.rule.contains(command))
        }
    }

    @Test func aSpacedServiceIsQuotedAndTheRuleEndsWithANewline() throws {
        let privilege = try JSONDecoder().decode(NetPrivilege.self, from: fixture("net-privilege.json"))
        #expect(privilege.allowed[0].contains("\"USB 10/100/1000 LAN\""))
        #expect(privilege.allowed[1] == "/usr/sbin/ipconfig set en5 DHCP")
        #expect(privilege.rule.hasSuffix("\n"))
        #expect(privilege.path.split(separator: "/").last?.contains(".") == false)
    }

    @Test func thePermissionKeysAreTranslatedInEveryLanguage() {
        for key in ["netRemember", "netRemembered", "netRememberExplain", "netForget", "netRememberFailed", "netNeedsPermission"] {
            for lang in Lang.allCases {
                #expect(L10n.table(lang)[key] != nil, "\(lang)/\(key)")
            }
        }
    }
}