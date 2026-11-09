import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("source contracts")
struct SourceContractTests {
    private var viewsDirectory: URL { appSources.appendingPathComponent("DustlessApp/Views") }
    private var servicesDirectory: URL { appSources.appendingPathComponent("DustlessApp/Services") }

    private func sourceFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: viewsDirectory,
            includingPropertiesForKeys: nil
        )
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func functionBody(of url: URL, startingAt marker: String) throws -> [String] {
        let all = try lines(of: url)
        let start = try #require(all.firstIndex { $0.contains(marker) })
        var end = start + 1
        while end < all.count && !all[end].trimmingCharacters(in: .whitespaces).hasPrefix("func ") {
            end += 1
        }
        return Array(all[(start + 1)..<min(end, all.count)])
    }

    @Test func theConfirmSheetHasNoDefaultAction() throws {
        let file = viewsDirectory.appendingPathComponent("ConfirmDeleteSheet.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            !text.contains(".keyboardShortcut(.defaultAction)"),
            "the delete button must not be the default action of the confirm sheet"
        )
        let shortcuts = try lines(of: file).filter { $0.contains(".keyboardShortcut(") }
        #expect(
            shortcuts.count == 1,
            "the confirm sheet must have exactly one keyboard shortcut, got \(shortcuts)"
        )
        #expect(
            shortcuts[0].contains(".cancelAction"),
            "the only shortcut in the confirm sheet must be the cancel action, got \(shortcuts[0])"
        )
    }

    @Test func theConfirmSheetHasNoReturnShortcut() throws {
        let file = viewsDirectory.appendingPathComponent("ConfirmDeleteSheet.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            !text.contains(".keyboardShortcut(.return"),
            "Return must never delete; the confirm sheet must not answer Return"
        )
        #expect(
            !text.contains(".keyboardShortcut(.defaultAction)"),
            "Return must never delete; the confirm sheet must not take the default action"
        )
    }

    @Test func theDeleteShortcutOpensTheReviewAndDoesNotDelete() throws {
        let file = viewsDirectory.appendingPathComponent("DetailView.swift")
        let lines = try lines(of: file)
        let index = try #require(
            lines.firstIndex { $0.contains("cleanup.review") },
            "the review button must carry an identifier"
        )
        let window = lines[max(0, index - 12)...index]
        #expect(
            window.contains { $0.contains(".keyboardShortcut(.return, modifiers: .command)") },
            "the review button must answer ⌘↩ so the user can reach the review sheet"
        )
    }

    @Test func noSheetTakesTheDefaultAction() throws {
        var found: [String] = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".keyboardShortcut(.defaultAction)") {
                found.append(file.lastPathComponent)
            }
        }
        #expect(
            found.isEmpty,
            "no sheet may answer Return with a destructive action, found \(found)"
        )
    }

    @Test func theStoreCleansOnlyFromAReadyPhase() throws {
        let file = servicesDirectory.appendingPathComponent("ScanStore.swift")
        let body = try functionBody(of: file, startingAt: "func clean() async {")
        let first = try #require(body.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(
            first.contains("guard phase == .ready else { return }"),
            "clean must refuse while a scan or apply is already running, first body line was \(first)"
        )
    }

    @Test func theStorageGuardsLockOutReentry() throws {
        let file = servicesDirectory.appendingPathComponent("StorageControl.swift")
        let trash = try functionBody(of: file, startingAt: "func trash(")
        let firstTrash = try #require(trash.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(
            firstTrash.contains("guard !isTrashingFile else { return }"),
            "trash must refuse a second run while one is in flight, first body line was \(firstTrash)"
        )
        let applications = servicesDirectory.appendingPathComponent("ApplicationsControl.swift")
        let uninstall = try functionBody(of: applications, startingAt: "func uninstall(")
        #expect(
            uninstall.contains { $0.contains("guard !isWorking else { return }") },
            "uninstall must refuse a second run while one is in flight"
        )
    }

    @Test func noCombinedElementWrapsAButton() throws {
        var offenders: [String] = []
        for file in try sourceFiles() {
            let lines = try lines(of: file)
            for (index, line) in lines.enumerated() where line.contains(".accessibilityElement(children: .combine)") {
                let indent = indentation(of: line)
                var chain: [String] = [line]
                var cursor = index - 1
                while cursor >= 0 {
                    let candidate = lines[cursor]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        cursor -= 1
                        continue
                    }
                    if indentation(of: candidate) < indent { break }
                    chain.append(candidate)
                    cursor -= 1
                }
                if chain.contains(where: { $0.contains("Button(") }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            "an element that combines its children must not wrap a button, found \(offenders)"
        )
    }

    @Test func theAppNeverAsksAppKitForADocument() throws {
        let file = appSources.appendingPathComponent("DustlessApp/DustlessApp.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            !text.contains("NSDocumentController") && !text.contains("newDocument"),
            "Dustless has no document types; asking NSDocumentController for a document only produces a system alert"
        )
        #expect(
            text.contains("WindowGroup(\"Dustless\", id: \"main\")"),
            "the main window needs a stable scene id so openWindow can recreate it"
        )
        #expect(
            text.contains("openWindow(id: \"main\")"),
            "the app must reopen its own window instead of asking for a document"
        )
    }

    @Test func theModuleWriteStaysSynchronous() throws {
        let router = try String(contentsOf: appSources.appendingPathComponent("DustlessApp/Services/AppRouter.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: viewsDirectory.appendingPathComponent("SidebarView.swift"), encoding: .utf8)
        #expect(!router.contains("withAnimation"), "the module value must be written synchronously")
        #expect(!sidebar.contains("List(selection:"), "the sidebar must not have a list selection binding")
        #expect(sidebar.contains("sidebar.module."), "the sidebar rows must keep their stable identifiers")
    }

    @Test func memoryHasADirectQuitAction() throws {
        let file = viewsDirectory.appendingPathComponent("MemoryView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("private func quitRow("), "the quit action must live on the group row, not inside the expansion")
        #expect(text.contains("memory.quit.\\(group.id)"), "the group row must expose its direct quit action")
        #expect(text.contains("stopping.contains(proc.pid)"), "a process stop must only lock its own row")
    }

    @Test func theApplicationSheetIsTheOnlyDestructiveApplicationGate() throws {
        let view = try String(contentsOf: viewsDirectory.appendingPathComponent("ApplicationsView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: viewsDirectory.appendingPathComponent("ApplicationsSheet.swift"), encoding: .utf8)
        let text = view + "\n" + sheet
        #expect(text.contains("applications.confirm"), "the application sheet must expose one confirm control")
        #expect(text.contains("applications.cancel"), "the application sheet must expose one cancel control")
        #expect(text.contains("appsIncludeRelated"), "the sheet must let the user keep related data")
        #expect(text.contains("isRunning"), "the sheet must know whether the app is running")
    }

    @Test func everyPopoverNavigationOpensTheWindow() throws {
        let file = viewsDirectory.appendingPathComponent("MenuBarContent.swift")
        let all = try lines(of: file)
        var offenders: [Int] = []
        for (index, line) in all.enumerated() {
            guard line.contains("router.select(") || line.contains("showingConfirmation = true") else { continue }
            let window = all[max(0, index - 8)..<index]
            if !window.contains(where: { $0.contains("onOpenWindow()") }) {
                offenders.append(index + 1)
            }
        }
        #expect(
            offenders.isEmpty,
            "a popover action changes the module or asks for the confirmation without opening the main window, lines \(offenders)"
        )
    }

    @Test func noViewRendersAReasonCodeDirectly() throws {
        var offenders: [String] = []
        for file in try sourceFiles() {
            let lines = try lines(of: file)
            for (index, line) in lines.enumerated() where line.contains(".code") {
                offenders.append("\(file.lastPathComponent):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(
            offenders.isEmpty,
            "a reason must be shown through ReasonText, never as its raw code, found \(offenders)"
        )
    }

    @Test func everyReasonOnScreenGoesThroughTheReasonTextHelper() throws {
        var offenders: [String] = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".note") && !text.contains("ReasonText.text(") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            "a view that shows a finding's reasons must render them with ReasonText, found \(offenders)"
        )
    }
}
