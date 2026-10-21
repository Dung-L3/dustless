import Testing
import Foundation
import DustlessKit
@Suite("panel filters")
struct PanelFilterTests {
    private func installedApp(name: String, bundleId: String, path: String) -> InstalledApp {
        InstalledApp(bundleId: bundleId, name: name, path: path, bytes: 1, relatedPaths: [])
    }

    @Test func anAppIsFoundByNameBundleIdOrPath() {
        let app = installedApp(
            name: "Visual Studio Code",
            bundleId: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app"
        )
        #expect(app.matches("visual studio"))
        #expect(app.matches("microsoft.vscode"))
        #expect(app.matches("/applications/"))
        #expect(!app.matches("firefox"))
    }

    @Test func noNeedleMeansNoFilter() throws {
        let app = installedApp(name: "Anything", bundleId: "x", path: "/x")
        #expect(app.matches(""))
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(files.allSatisfy { $0.matches("") })
        let group = try #require(try [process(command: "/usr/bin/x")].groupedByApp().first)
        #expect(group.matches(""))
        #expect(group.contains(category: .other))
    }

    @Test func aFileIsFoundByNameOrFolder() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        let file = try #require(files.first { $0.name == "screen recording.mov" })
        #expect(file.matches("screen recording"))
        #expect(file.matches((file.path as NSString).deletingLastPathComponent.lowercased()))
        #expect(!file.matches("a name that is in no folder of this list"))
    }

    @Test func aGroupIsFoundByAHelperProcessNameToo() throws {
        let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer) --type=renderer"
        let groups = try [process(command: renderer, mem: 900, pid: 4242)].groupedByApp()

        let group = try #require(groups.first)
        #expect(group.matches("brave browser"))
        #expect(group.matches("brave browser.app"))
        #expect(group.matches("(renderer)"))
        #expect(group.matches("4242"))
        #expect(!group.matches("42"))
        #expect(!group.matches("safari"))
    }

    @Test func aGroupJoinsTheCategoryOfAnyProcessItOwns() throws {
        let browser = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        let groups = try [
            process(command: browser, mem: 10, pid: 1),
            process(command: "/usr/libexec/thingd", mem: 5, pid: 2),
        ].groupedByApp()

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.contains(category: .other) })
        #expect(groups.allSatisfy { !$0.contains(category: .browser) })
    }
}
