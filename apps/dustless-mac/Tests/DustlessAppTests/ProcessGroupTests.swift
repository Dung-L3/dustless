import Testing
import Foundation
import DustlessKit
@Suite("process grouping")
struct ProcessGroupTests {
    @Test func helpersJoinTheirApplicationBundle() throws {
        let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/155/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer) --type=renderer"
        let groups = try [process(command: brave, mem: 100), process(command: renderer, mem: 50)]
            .groupedByApp()

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.id == "/Applications/Brave Browser.app")
        #expect(group.bundlePath == "/Applications/Brave Browser.app")
        #expect(group.label == "Brave Browser")
        #expect(group.count == 2)
        #expect(group.bytes == 150)
    }

    @Test func theDisplayNameShowsTheLastPathComponentWithoutABundle() throws {
        let groups = try [process(command: "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices -x")]
            .groupedByApp()
        let group = try #require(groups.first)
        #expect(group.label.hasPrefix("/System/Library"), "the label stays the full path")
        #expect(group.displayName == "CoreServices")
    }

    @Test func theDisplayNameKeepsABundleName() throws {
        let groups = try [process(command: "/Applications/Safari.app/Contents/MacOS/Safari")]
            .groupedByApp()
        #expect(groups.first?.displayName == "Safari")
    }

    @Test func bundleNamesMayContainSpaces() throws {
        let groups = try [process(command: "/Users/me/Apps/My Cool App.app/Contents/MacOS/cool")]
            .groupedByApp()
        #expect(groups.first?.label == "My Cool App")
        #expect(groups.first?.id == "/Users/me/Apps/My Cool App.app")
    }

    @Test func processesWithoutABundleGroupOnTheirExecutable() throws {
        let groups = try [
            process(command: "/usr/libexec/thingd --daemon"),
            process(command: "/usr/libexec/thingd -v"),
            process(command: "/usr/sbin/cron"),
            process(command: "node server.js"),
        ].groupedByApp()

        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.bundlePath == nil })
        let thingd = try #require(groups.first { $0.label.hasPrefix("/usr/libexec/thingd") })
        #expect(thingd.count == 2)
        #expect(thingd.label == "/usr/libexec/thingd", "no bundle, so the path is the label")
        #expect(groups.contains { $0.label == "node" })
    }

    @Test func thingsThatMerelyEndInAppAreNotBundles() throws {
        let groups = try [
            process(command: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/WebContent"),
            process(command: "/usr/bin/mapper --out=/tmp/report.app"),
        ].groupedByApp()

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.bundlePath == nil })
        #expect(groups.contains { $0.label == "/usr/bin/mapper" })
    }

    @Test func groupsSortByTotalMemoryNotByTheirBiggestProcess() throws {
        let groups = try [
            process(command: "/usr/bin/small", mem: 100),
            process(command: "/usr/bin/one", mem: 10),
            process(command: "/usr/bin/two", mem: 10),
            process(command: "/usr/bin/three", mem: 10),
        ].groupedByApp()

        #expect(groups.map(\.bytes) == [100, 10, 10, 10])
        #expect(groups.first?.bytes == 100)
        #expect(groups.last?.bytes == 10)
    }

    @Test func tiesBreakOnTheGroupKey() throws {
        let procs = try [process(command: "/usr/bin/b"), process(command: "/usr/bin/a", pid: 2)]
        #expect(procs.groupedByApp().map(\.id) == ["/usr/bin/a", "/usr/bin/b"])
    }

    @Test func groupMembersAreSortedBiggestFirst() throws {
        let group = try #require(try [
            process(command: "/usr/bin/a", mem: 1, pid: 1),
            process(command: "/usr/bin/a", mem: 9, pid: 2),
            process(command: "/usr/bin/a", mem: 5, pid: 3),
        ].groupedByApp().first)
        #expect(group.processes.map(\.mem) == [9, 5, 1])
    }

    @Test func everyProcessLandsInExactlyOneGroup() throws {
        let procs = try (0..<20).map { try process(command: "/usr/bin/p\($0 % 4)", mem: UInt64($0), pid: $0) }
        let groups = procs.groupedByApp()
        let bytes = groups.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(groups.count == 4)
        #expect(groups.reduce(0) { $0 + $1.count } == procs.count)
        #expect(bytes == procs.reduce(UInt64(0)) { $0 + $1.mem })
        #expect(Set(groups.flatMap(\.processes)).count == procs.count)
    }

    @Test func noProcessesIsNoGroups() {
        let none: [MemProcess] = []
        #expect(none.groupedByApp().isEmpty)
    }

    @Test func groupingNeverLosesAnythingFromTheRealPayload() throws {
        let report = try JSONDecoder().decode(MemoryReport.self, from: fixture("ram.json"))
        let groups = report.processes.groupedByApp()

        #expect(groups.reduce(UInt64(0)) { $0 + $1.bytes } == report.processes.reduce(UInt64(0)) { $0 + $1.mem })
        #expect(Set(groups.flatMap(\.processes)) == Set(report.processes))
        #expect(groups.map(\.bytes) == groups.map(\.bytes).sorted(by: >))
        #expect(groups.contains { $0.bundlePath == "/Applications/Stremio.app" && $0.label == "Stremio" })
    }
}
