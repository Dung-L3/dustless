import DustlessKit
import SwiftUI
import AppKit

struct KillStatus: Identifiable {
    let id = UUID()
    let pid: Int
    let ok: Bool
    let reason: KillReason?
}

enum KillReason {
    case engine(String)
    case translated(L10nText)
}

struct MemoryProcessRow: View {
    let proc: MemProcess
    let status: KillStatus?
    let isStopping: Bool
    let onStop: (MemProcess) -> Void
    let onForceStop: (MemProcess) -> Void
    let onStatusCleared: (Int) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PanelStyle.Space.s) {
            Text(proc.name)
                .font(PanelFont.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(proc.command)
                .accessibilityLabel(rowDescription)

            Spacer(minLength: 6)

            Text(String(proc.pid))
                .font(PanelFont.mono(12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .textSelection(.enabled)
                .contextMenu {
                    Button(settings.t("memoryCopyPID")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(proc.pid), forType: .string)
                    }
                }
                .accessibilityLabel("\(settings.t("memoryProcessPID")) \(proc.pid)")

            Text(ByteFormat.string(proc.mem))
                .font(PanelFont.number())
                .frame(minWidth: 64, alignment: .trailing)

            stopButton
        }
        .padding(.vertical, 3)
    }

    private var rowDescription: String {
        [
            proc.name,
            settings.t("memoryProcessPID") + " " + "\(proc.pid)",
            settings.t(categoryKey(proc.category)),
            ByteFormat.string(proc.mem),
        ].joined(separator: ", ")
    }

    @ViewBuilder
    private var stopButton: some View {
        if let status {
            statusView(status)
        } else {
            Button(action: { onStop(proc) }) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(settings.t("memoryStopAction"))
                        .font(PanelFont.caption)
                }
                .foregroundStyle(DestructiveStyle.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DestructiveStyle.red.opacity(0.12), in: .rect(cornerRadius: 5))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityLabel(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityIdentifier("memory.stop.\(proc.pid)")
            .contextMenu {
                Button(action: { onForceStop(proc) }) {
                    Label(
                        settings.t("memoryForceStopNamed", ["name": proc.name]),
                        systemImage: "exclamationmark.octagon.fill"
                    )
                }
            }
            .disabled(isStopping)
        }
    }

    @ViewBuilder
    private func statusView(_ status: KillStatus) -> some View {
        let tint = status.ok ? Color.green : Color.red
        let label = status.ok
            ? settings.t("memoryStoppedNamed", ["name": proc.name])
            : (status.reason.map { reasonText($0) } ?? settings.t("memoryStopError"))
        Image(systemName: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("memory.status.\(proc.pid)")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { clearStatus(status.pid) }
                }
            }
    }

    private func clearStatus(_ pid: Int) {
        onStatusCleared(pid)
    }

    private func reasonText(_ reason: KillReason) -> String {
        switch reason {
        case .engine(let sentence): sentence
        case .translated(let text): settings.text(text)
        }
    }

    private func categoryKey(_ category: MemCategory) -> String {
        switch category {
        case .browser: return "categoryBrowser"
        case .editor: return "categoryEditor"
        case .container: return "categoryContainer"
        case .lsp: return "categoryLSP"
        case .other: return "categoryOther"
        }
    }
}
