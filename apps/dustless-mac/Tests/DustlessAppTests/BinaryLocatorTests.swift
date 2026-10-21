import Foundation
import Testing
import DustlessKit

private func machOBinary() throws -> URL {
    for candidate in ["/bin/echo", "/usr/bin/true", "/bin/cat"] {
        let url = URL(fileURLWithPath: candidate)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    throw CocoaError(.fileNoSuchFile)
}

private struct FakeBundle {
    let root: URL
    let bundle: URL
    let macOS: URL
    let resources: URL
    let resourcesBin: URL
    let appExecutable: URL

    var engineCandidate: URL { resources.appendingPathComponent("dustless") }

    static func make() throws -> FakeBundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dustless-bundle-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Dustless.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let resourcesBin = resources.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesBin, withIntermediateDirectories: true)
        let appExecutable = macOS.appendingPathComponent("Dustless")
        try FileManager.default.copyItem(at: try machOBinary(), to: appExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExecutable.path)
        return FakeBundle(
            root: root,
            bundle: bundle,
            macOS: macOS,
            resources: resources,
            resourcesBin: resourcesBin,
            appExecutable: appExecutable
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func context(roots: [URL]) -> BinarySearchContext {
        BinarySearchContext(roots: roots, ownExecutable: appExecutable)
    }
}

private func locateError(_ context: BinarySearchContext) -> BinaryLocationError? {
    do {
        _ = try BinaryLocator.locate(in: context)
        return nil
    } catch let error as BinaryLocationError {
        return error
    } catch {
        return nil
    }
}

private func located(_ context: BinarySearchContext) -> URL? {
    try? BinaryLocator.locate(in: context)
}

private actor RecordingLauncher: EngineLauncher {
    private var recorded: [URL] = []

    var spawns: [URL] { recorded }

    func launch(executable: URL, arguments: [String], timeout: Int) async throws -> EngineRun {
        recorded.append(executable)
        return EngineRun(data: Data("{}".utf8), status: 0, stderr: "")
    }
}

@Suite("engine binary location")
struct BinaryLocatorTests {
    @Test func findsTheEngineWhenItExistsAndIsExecutable() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try FileManager.default.copyItem(at: try machOBinary(), to: bundle.engineCandidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.engineCandidate.path)

        let context = bundle.context(roots: [bundle.resources, bundle.resourcesBin, bundle.bundle])
        #expect(located(context) == bundle.engineCandidate)
    }

    @Test func refusesTheAppsOwnExecutableUnderTheEngineName() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try FileManager.default.linkItem(at: bundle.appExecutable, to: bundle.engineCandidate)

        let context = bundle.context(roots: [bundle.resources, bundle.resourcesBin, bundle.macOS])
        guard case .notFound(let searched)? = locateError(context) else {
            Issue.record("expected the app's own executable to be refused")
            return
        }
        #expect(searched == [
            bundle.engineCandidate,
            bundle.resourcesBin.appendingPathComponent("dustless"),
            bundle.macOS.appendingPathComponent("dustless"),
        ])
        #expect(located(context) != bundle.appExecutable)
    }

    @Test func refusesTheCaseOnlySpellingOfTheAppsOwnExecutable() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }

        let lowerCase = bundle.macOS.appendingPathComponent("dustless")
        let context = bundle.context(roots: [bundle.macOS])
        guard case .notFound? = locateError(context) else {
            Issue.record("expected the app's own executable to be refused")
            return
        }
        if lowerCase.resolvingSymlinksInPath() == bundle.appExecutable.resolvingSymlinksInPath() {
            #expect(located(context) == nil, "the case-only spelling of the app's own executable must be refused")
        }
    }

    @Test func refusesASymlinkThatPointsAtTheAppsOwnExecutable() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try FileManager.default.createSymbolicLink(
            at: bundle.engineCandidate,
            withDestinationURL: bundle.appExecutable
        )

        let context = bundle.context(roots: [bundle.resources, bundle.resourcesBin, bundle.macOS])
        guard case .notFound? = locateError(context) else {
            Issue.record("expected the symlink to the app's own executable to be refused")
            return
        }
        #expect(located(context) != bundle.appExecutable)
    }

    @Test func aMissingEngineNamesEverySearchedPath() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }

        let context = bundle.context(roots: [bundle.resources, bundle.resourcesBin, bundle.bundle])
        guard case .notFound(let searched)? = locateError(context) else {
            Issue.record("expected a not-found error")
            return
        }
        #expect(searched == [
            bundle.engineCandidate,
            bundle.resourcesBin.appendingPathComponent("dustless"),
            bundle.bundle.appendingPathComponent("dustless"),
        ])
        let rendered = L10n.text(.en, locateError(context)?.localized ?? L10nText("errNotFound"))
        for path in searched {
            #expect(rendered.contains(path.path), "the message must name \(path.path)")
        }
    }

    @Test func aNonExecutableEngineIsReported() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try Data("engine".utf8).write(to: bundle.engineCandidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundle.engineCandidate.path)

        let context = bundle.context(roots: [bundle.resources])
        guard case .notExecutable(let url)? = locateError(context) else {
            Issue.record("expected a not-executable error")
            return
        }
        #expect(url == bundle.engineCandidate)
        let rendered = L10n.text(.en, locateError(context)?.localized ?? L10nText("errNotExecutable"))
        #expect(rendered.contains(bundle.engineCandidate.path))
    }

    @Test func aCandidateThatIsNotTheEngineIsReported() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try Data("not a binary".utf8).write(to: bundle.engineCandidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.engineCandidate.path)

        let context = bundle.context(roots: [bundle.resources])
        guard case .notAnEngine(let url, _)? = locateError(context) else {
            Issue.record("expected a not-an-engine error")
            return
        }
        #expect(url == bundle.engineCandidate)
        let rendered = L10n.text(.en, locateError(context)?.localized ?? L10nText("errGeneric"))
        #expect(rendered.contains(bundle.engineCandidate.path))
    }

    @Test func anEngineThatIsAScriptIsAccepted() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundle.engineCandidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.engineCandidate.path)

        let context = bundle.context(roots: [bundle.resources])
        #expect(located(context) == bundle.engineCandidate)
    }

    @Test func aRejectedCandidateNeverFallsThroughToTheAppsOwnExecutable() throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        try FileManager.default.linkItem(at: bundle.appExecutable, to: bundle.engineCandidate)

        let context = bundle.context(roots: [bundle.resources, bundle.macOS])
        guard case .notFound? = locateError(context) else {
            Issue.record("expected the search to end without the app's own executable")
            return
        }
        #expect(located(context) == nil)
    }

    @Test func theProductionRootsNeverIncludeTheMacOSExecutableFolder() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Dustless.app", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let roots = BinaryLocator.roots(resourceURL: resources, bundleURL: bundle)

        #expect(roots == [
            resources,
            resources.appendingPathComponent("bin", isDirectory: true),
            bundle,
        ])
        #expect(!roots.contains { $0.path.contains("/Contents/MacOS") })
        #expect(BinaryLocator.current.roots == BinaryLocator.roots(
            resourceURL: Bundle.main.resourceURL,
            bundleURL: Bundle.main.bundleURL
        ))
        #expect(BinaryLocator.current.ownExecutable == Bundle.main.executableURL)
    }

    @Test func noDefaultCandidateIsTheApplicationsOwnExecutable() throws {
        let context = BinaryLocator.current
        let own = Bundle.main.executableURL
        for candidate in BinaryLocator.candidates(in: context) {
            #expect(!BinaryLocator.isOwnExecutable(candidate, own: own))
        }
    }

    @Test func aMissingEngineNeverSpawnsAChildOfTheApp() async throws {
        let bundle = try FakeBundle.make()
        defer { bundle.remove() }
        let launcher = RecordingLauncher()

        let context = bundle.context(roots: [bundle.resources, bundle.resourcesBin, bundle.macOS])
        do {
            let cli = try DustlessCLI.resolve(context: context, launcher: launcher)
            _ = try await cli.scan()
            Issue.record("expected the missing engine to throw")
        } catch {
            #expect(error is BinaryLocationError)
        }
        #expect(await launcher.spawns.isEmpty, "the app must never run a child copy of itself")
        #expect(await launcher.spawns.allSatisfy { $0 != bundle.appExecutable })
    }
}
