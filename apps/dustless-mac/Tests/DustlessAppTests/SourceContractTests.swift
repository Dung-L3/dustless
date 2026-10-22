import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("source contracts")
struct SourceContractTests {
    private var viewsDirectory: URL { appSources.appendingPathComponent("DustlessApp/Views") }

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

    @Test func theDefaultActionIsConfinedToTheStorageSheets() throws {
        var found: [String] = []
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".keyboardShortcut(.defaultAction)") {
                found.append(file.lastPathComponent)
            }
        }
        #expect(
            found == ["StorageSheets.swift"],
            "only the storage sheets may take the default action, found \(found)"
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
