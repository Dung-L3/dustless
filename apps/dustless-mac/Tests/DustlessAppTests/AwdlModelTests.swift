import Testing
import Foundation
import DustlessKit
@Suite("awdl model")
struct AwdlModelTests {
    @Test func decodesAStatusReport() throws {
        let report = try JSONDecoder().decode(AwdlReport.self, from: fixture("awdl.json"))
        #expect(report.platform == "mac")
        #expect(report.interface == "awdl0")
        #expect(report.state == .on)
        #expect(report.changed == false)
        #expect(report.outcome == nil, "a read-only status call carries no outcome")
    }

    @Test func thePrivilegeRuleIsScopedToTwoExactCommands() throws {
        let privilege = try JSONDecoder().decode(AwdlPrivilege.self, from: fixture("awdl-privilege.json"))
        #expect(privilege.path == "/etc/sudoers.d/dustless-awdl")
        #expect(privilege.allowed == ["/sbin/ifconfig awdl0 down", "/sbin/ifconfig awdl0 up"])
        #expect(privilege.rule.contains("NOPASSWD:"))
        #expect(!privilege.rule.contains("*"))
        #expect(privilege.rule.contains(privilege.allowed[0]))
        #expect(privilege.rule.contains(privilege.allowed[1]))
    }

    @Test func thePrivilegeFileNameHasNoDotWhichSudoWouldIgnore() throws {
        let privilege = try JSONDecoder().decode(AwdlPrivilege.self, from: fixture("awdl-privilege.json"))
        #expect(privilege.path.split(separator: "/").last?.contains(".") == false)
        #expect(privilege.rule.hasSuffix("\n"))
    }

    @Test func decodesAToggleOutcome() throws {
        let ran = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"mac","interface":"awdl0","state":"off","changed":true,"outcome":{"status":"ran","detail":"awdl0 down"}}
        """#.utf8))
        #expect(ran.state == .off)
        #expect(ran.changed)
        #expect(ran.outcome?.status == .ran)

        let refused = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"mac","interface":"awdl0","state":"on","changed":false,"outcome":{"status":"refused","detail":"needs root"}}
        """#.utf8))
        #expect(refused.outcome?.status == .refused)
        #expect(refused.changed == false)
    }

    @Test func notApplicableKeepsItsHyphenatedWireValue() throws {
        let report = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"linux","interface":null,"state":"absent","changed":false,"outcome":{"status":"not-applicable","detail":"macOS only"}}
        """#.utf8))
        #expect(report.interface == nil)
        #expect(report.state == .absent)
        #expect(report.outcome?.status == .notApplicable)
    }

    @Test func rejectsAnUnknownStateRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AwdlReport.self, from: Data(#"{"platform":"mac","state":"maybe","changed":false}"#.utf8))
        }
    }
}
