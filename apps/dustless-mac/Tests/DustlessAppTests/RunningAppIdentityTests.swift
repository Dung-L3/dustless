import Foundation
import Testing
@testable import DustlessApp

@Suite("running app identity")
struct RunningAppIdentityTests {
    @Test func aSymlinkedBundlePathIsTheSameApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustless-running-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let target = apps.appendingPathComponent("Toy.app", isDirectory: true)
        let link = root.appendingPathComponent("Linked Toy.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(RunningAppIdentity.isSamePath(link.path, target.path))
        #expect(RunningAppIdentity.isSamePath(target.path + "/../Toy.app", target.path))
    }

    @Test func aSiblingCopyIsNotTheSameApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustless-running-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("Applications/Toy.app")
        let second = root.appendingPathComponent("Applications/Toy Copy.app")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        #expect(!RunningAppIdentity.isSamePath(first.path, second.path))
    }

    @Test func anUnknownBundlePathNeverMatches() {
        #expect(!RunningAppIdentity.isSamePath(nil, "/Applications/Toy.app"))
    }
}
