import DustlessKit
import SwiftUI

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?
    @EnvironmentObject private var settings: AppSettings

    @State private var volumes: [VolumeInfo] = []
    @State private var apps: [InstalledApp] = []
    @State private var isLoadingApps = false
    @State private var appsError: String?
    @State private var selectedAppForUninstall: InstalledApp?
    @State private var uninstallReport: UninstallReport?
    @State private var isUninstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    volumesSection
                    Divider()
                    applicationsSection
                    if let reclaimable {
                        Divider()
                        reclaimableSection(reclaimable)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
        .task {
            await loadVolumes()
            await loadApps()
        }
        .sheet(item: $selectedAppForUninstall) { app in
            UninstallConfirmationSheet(
                app: app,
                settings: settings,
                onCancel: { selectedAppForUninstall = nil },
                onConfirm: { Task { await performUninstall(app) } }
            )
        }
        .sheet(item: $uninstallReport) { report in
            UninstallResultSheet(report: report, settings: settings, onDismiss: { uninstallReport = nil })
        }
    }

    private var header: some View {
        HStack {
            Text(settings.t("storage"))
                .font(.title2.weight(.semibold))
            if let name = space.volumeName, !name.isEmpty {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { NSApp.keyWindow?.close() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
        }
    }

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.t("volumesTitle"))
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(volumes) { volume in
                    VolumeCard(volume: volume, settings: settings)
                }
            }
        }
    }

    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.t("appsTitle"))
                    .font(.headline)
                Spacer()
                if isLoadingApps {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = appsError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if apps.isEmpty && !isLoadingApps {
                Text(settings.t("nothingScanned"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(apps) { app in
                        AppRow(app: app, settings: settings, onUninstall: { selectedAppForUninstall = app })
                    }
                }
            }
        }
    }

    private var usageBar: some View {
        ProgressView(value: Double(space.used), total: Double(space.total))
            .frame(height: 8)
    }

    private func reclaimableSection(_ reclaimable: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(settings.t("reclaimableMetric"))
                    .font(.headline)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(settings.t("reclaimableHelp"))
            }
            Text(ByteFormat.string(reclaimable))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text(settings.t("storageNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(settings.t("done")) {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func loadVolumes() async {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard let total = values.volumeTotalCapacity,
                      let available = values.volumeAvailableCapacity,
                      total > 0, available >= 0 else { continue }
                let totalU = UInt64(total)
                let availableU = UInt64(available)
                let used = totalU - availableU
                let name = values.volumeName ?? url.lastPathComponent
                result.append(VolumeInfo(name: name, total: totalU, used: used, free: availableU))
            } catch {
                continue
            }
        }
        volumes = result
    }

    private func loadApps() async {
        isLoadingApps = true
        appsError = nil
        do {
            let cli = try DustlessCLI.resolve()
            let fetchedApps = try await cli.apps()
            apps = fetchedApps.sorted { $0.bytes > $1.bytes }
        } catch {
            appsError = error.localizedDescription
        }
        isLoadingApps = false
    }

    private func performUninstall(_ app: InstalledApp) async {
        isUninstalling = true
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(path: app.path)
            uninstallReport = report
            selectedAppForUninstall = nil
            await loadApps()
        } catch {
            // Error handling could be improved
        }
        isUninstalling = false
    }
}

struct VolumeInfo: Identifiable {
    let id = UUID()
    let name: String
    let total: UInt64
    let used: UInt64
    let free: UInt64

    var usedPercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(volume.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            ProgressView(value: volume.usedPercent)
                .frame(height: 6)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t("volumeTotal"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(volume.total))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t("volumeUsed"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(volume.used))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t("volumeFree"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(volume.free))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppRow: View {
    let app: InstalledApp
    let settings: AppSettings
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                Text(app.bundleId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.string(app.bytes))
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("\(app.relatedPaths.count) \(settings.t("relatedFiles"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsUninstall")) {
                onUninstall()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }
}

struct UninstallConfirmationSheet: View {
    let app: InstalledApp
    let settings: AppSettings
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // App itself
                    AppUninstallRow(
                        name: app.name,
                        path: app.path,
                        bytes: app.bytes,
                        isApp: true,
                        settings: settings
                    )
                    Divider().opacity(0.4).padding(.horizontal, 14)

                    // Related files
                    ForEach(app.relatedPaths, id: \.self) { related in
                        AppUninstallRow(
                            name: (related as NSString).lastPathComponent,
                            path: related,
                            bytes: nil,
                            isApp: false,
                            settings: settings
                        )
                        Divider().opacity(0.4).padding(.horizontal, 14)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 380, idealHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(settings.t("appsTrashTitle"))
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(settings.t("appsTrashBody", ["n": "\(app.relatedPaths.count)"]))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Text(settings.t("totalLabel"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.t("confirmTotal", ["amount": ByteFormat.string(totalBytes)]))

            HStack(spacing: 10) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(settings.t("appsMoveToTrash"))
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var totalBytes: UInt64 {
        // The CLI reports the leftover paths but not their individual sizes.
        app.bytes
    }
}

struct AppUninstallRow: View {
    let name: String
    let path: String
    let bytes: UInt64?
    let isApp: Bool
    let settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isApp ? "app.fill" : "doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isApp ? .blue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: isApp ? .medium : .regular))
                    .textSelection(.enabled)
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            if let bytes {
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
    }
}

struct UninstallResultSheet: View {
    let report: UninstallReport
    let settings: AppSettings
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("appsUninstalled"))
                    .font(.system(size: 16, weight: .semibold))
                Text(settings.t("resultSummary", [
                    "freed": ByteFormat.string(report.summary.totalBytes),
                    "elapsed": "0 ms",
                    "free": ByteFormat.string(report.summary.totalBytes),
                ]))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.outcomes) { outcome in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: outcome.status))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(tint(for: outcome.status))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(outcome.path)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                                if !outcome.detail.isEmpty {
                                    Text(outcome.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .lineLimit(nil)
                                }
                            }
                            Spacer(minLength: 10)
                            Text(ByteFormat.string(outcome.bytes))
                                .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                                .frame(width: 66, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(settings.t("done"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 540)
    }

    private func symbol(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "checkmark.circle.fill"
        case .purged: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: UninstallOutcome.Status) -> Color {
        switch status {
        case .trashed: .green
        case .purged: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }
}