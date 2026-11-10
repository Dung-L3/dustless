import DustlessKit
import Foundation
import Testing
@testable import DustlessApp

@Suite("memory protection")
struct MemoryProtectionTests {
    private func process(name: String, root: Bool) throws -> DustlessKit.ProcessInfo {
        let json = """
        {"pid":42,"ppid":1,"name":"\(name)","command":"\(name)","cpu":0,"mem":100000000,"owner":"mac","root":\(root),"category":"other"}
        """
        return try JSONDecoder().decode(DustlessKit.ProcessInfo.self, from: Data(json.utf8))
    }

    @Test func rootOwnedProcessIsProtectedFromDirectActions() throws {
        #expect(try process(name: "WindowServer", root: true).isProtectedMemoryTarget)
    }

    @Test func dustlessItselfIsProtectedFromDirectActions() throws {
        #expect(try process(name: "Dustless", root: false).isProtectedMemoryTarget)
    }

    @Test func anOrdinaryUserProcessIsActionable() throws {
        #expect(try !process(name: "E2EDocker", root: false).isProtectedMemoryTarget)
    }
}
