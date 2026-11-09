import AppKit
import DustlessKit
import SwiftUI

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
        HStack(spacing: Theme.Space.s) {
            Text(proc.name)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(proc.command)
                .accessibilityLabel(rowDescription)

            if protected {
                StatusPill(text: settings.t("appsProtected"), tone: .danger, icon: "lock.fill")
                    .help(settings.t("memoryPressureHelp"))
            }

            Spacer(minLength: 6)

            Text(String(proc.pid))
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.textMuted)
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
                .font(Theme.Font.number(size: 12))
                .frame(minWidth: 64, alignment: .trailing)

            forceMenu
            stopButton
        }
        .padding(.vertical, 4)
    }

    private var protected: Bool {
        proc.root || proc.name.lowercased().contains("dustless")
    }

    private var rowDescription: String {
        [
            proc.name,
            settings.t("memoryProcessPID") + " " + "\(proc.pid)",
            settings.t(categoryKey(proc.category)),
            ByteFormat.string(proc.mem),
        ].joined(separator: ", ")
    }

    private var forceMenu: some View {
        Menu {
            Button {
                onStop(proc)
            } label: {
                Label(settings.t("memoryStopAction"), systemImage: "stop.circle")
            }
            Button {
                onForceStop(proc)
            } label: {
                Label(settings.t("memoryForceStopNamed", ["name": proc.name]), systemImage: "exclamationmark.octagon.fill")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help(settings.t("memoryStopNamed", ["name": proc.name]))
        .accessibilityLabel(settings.t("memoryStopNamed", ["name": proc.name]))
        .accessibilityIdentifier("memory.forceStop.menu.\(proc.pid)")
        .disabled(isStopping)
    }

    @ViewBuilder
    private var stopButton: some View {
        if let status {
            statusView(status)
        } else {
            Button(action: { onStop(proc) }) {
                HStack(spacing: 4) {
                    if isStopping {
                        ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(settings.t("memoryStopAction"))
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(Theme.Palette.danger)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.Palette.dangerFill, in: .capsule)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityLabel(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityIdentifier("memory.stop.\(proc.pid)")
            .disabled(isStopping)
        }
    }

    @ViewBuilder
    private func statusView(_ status: KillStatus) -> some View {
        let tint = status.ok ? Theme.Palette.accent : Theme.Palette.danger
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
                guard status.ok else { return }
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
