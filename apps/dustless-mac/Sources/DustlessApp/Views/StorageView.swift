import DustlessKit
import SwiftUI
import AppKit

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
    @State private var uninstallError: String?
    @State private var dataLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            // Volumes stay put at the top; the app list scrolls in the space
            // that is left. One long scroll made the volumes impossible to find
            // on a Mac with a dozen applications installed.
            volumesSection

            if let reclaimable {
                reclaimableSection(reclaimable)
            }

            Divider()

            applicationsSection
                .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 680)
        .background(.regularMaterial)
        .task {
            if !dataLoaded {
                await loadVolumes()
                await loadApps()
                dataLoaded = true
            }
        }
        .sheet(item: $selectedAppForUninstall) { app in
            UninstallConfirmationSheet(
                app: app,
                onCancel: { selectedAppForUninstall = nil },
                onConfirm: { Task { await performUninstall(app) } }
            )
        }
        .sheet(item: $uninstallReport) { report in
            UninstallResultSheet(report: report, onDismiss: { uninstallReport = nil })
        }
        .alert(settings.t("appsUninstall"), isPresented: .constant(uninstallError != nil), presenting: uninstallError) { _ in
            Button(settings.t("done")) { uninstallError = nil }
        } message: { error in
            Text(error)
        }
    }

    private var header: some View {
        PanelHeader(
            title: settings.t("storage"),
            subtitle: space.volumeName?.isEmpty == false ? space.volumeName : nil
        )
    }

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.t("volumesTitle"))
                .panelSectionHeader()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(volumes) { volume in
                    VolumeCard(volume: volume)
                }
            }
        }
    }

    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(settings.t("appsTitle"))
                    .panelSectionHeader()

                if !apps.isEmpty {
                    Text(settings.t("itemMany", ["n": "\(apps.count)"]))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PanelStyle.rowFill, in: .capsule)
                        .accessibilityLabel(settings.t("appsCount", ["n": "\(apps.count)"]))
                }

                Spacer(minLength: 0)

                if isLoadingApps {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            appsBody
        }
    }

    /// Three distinct states: still loading, failed with a retry, or the list.
    @ViewBuilder
    private var appsBody: some View {
        if let error = appsError {
            PanelStateView(
                kind: .error,
                message: error,
                title: settings.t("appsTitle"),
                actionTitle: settings.t("retry"),
                action: { Task { await loadApps() } }
            )
        } else if apps.isEmpty {
            // Zero applications is a real answer, not a reason to spin.
            PanelStateView(
                kind: isLoadingApps ? .loading : .empty,
                message: isLoadingApps ? settings.t("busyApps") : settings.t("appsEmpty")
            )
            .frame(minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(apps) { app in
                        AppRow(
                            app: app,
                            isUninstalling: isUninstalling,
                            onUninstall: { selectedAppForUninstall = app }
                        )
                    }
                }
            }
        }
    }

    /// One line, not a card: the volumes above are cards, and a fourth card here
    /// competed with them instead of summarising them.
    private func reclaimableSection(_ reclaimable: UInt64) -> some View {
        HStack(spacing: 8) {
            Text(settings.t("reclaimableMetric"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(settings.t("reclaimableHelp"))
                .accessibilityLabel(settings.t("reclaimableHelp"))

            Text(ByteFormat.string(reclaimable))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())

            Spacer(minLength: 8)

            Text(settings.t("storageNote"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
        defer { isUninstalling = false }
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(path: app.path)
            uninstallReport = report
            selectedAppForUninstall = nil
            await loadApps()
        } catch {
            uninstallError = error.localizedDescription
        }
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
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(volume.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(volume.usedPercent, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: volume.usedPercent)
                .frame(height: 6)
                .help(settings.t("volumeUsageHelp", ["name": volume.name]))

            HStack(spacing: 10) {
                MetricCard(
                    label: settings.t("volumeTotal"),
                    value: ByteFormat.string(volume.total),
                    compact: true
                )
                MetricCard(
                    label: settings.t("volumeUsed"),
                    value: ByteFormat.string(volume.used),
                    compact: true
                )
                MetricCard(
                    label: settings.t("volumeFree"),
                    value: ByteFormat.string(volume.free),
                    compact: true
                )
            }
        }
        .padding(12)
        .panelCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AppRow: View {
    let app: InstalledApp
    var isUninstalling: Bool = false
    let onUninstall: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.bundleId)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(app.bytes))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(settings.t("appsRelatedCount", ["n": "\(app.relatedPaths.count)"]))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsUninstall"), role: .destructive, action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isUninstalling)
                .help(settings.t("appsUninstallHelp", ["name": app.name]))
                .accessibilityLabel(settings.t("appsUninstallNamed", ["name": app.name]))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panelCard(PanelStyle.rowFill)
        .pathContextMenu(app.path)
        .accessibilityElement(children: .contain)
    }
}

struct UninstallConfirmationSheet: View {
    let app: InstalledApp
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

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
                        isApp: true
                    )
                    Divider().opacity(0.4).padding(.horizontal, 14)

                    // Related files
                    ForEach(app.relatedPaths, id: \.self) { related in
                        AppUninstallRow(
                            name: (related as NSString).lastPathComponent,
                            path: related,
                            bytes: nil,
                            isApp: false
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
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
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

    @EnvironmentObject private var settings: AppSettings

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
                    .help(path)
                    .accessibilityLabel(settings.t("pathA11y", ["path": path]))
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
        .pathContextMenu(path)
        .accessibilityElement(children: .combine)
    }
}

struct UninstallResultSheet: View {
    let report: UninstallReport
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("appsUninstalled"))
                    .font(.system(size: 16, weight: .semibold))
                Text(settings.t("appsResultSummary", [
                    "freed": ByteFormat.string(report.summary.totalBytes),
                    "count": "\(report.outcomes.count)",
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
                                .help(settings.t("outcomeStatus", ["status": settings.t(statusKey(for: outcome.status))]))
                                .accessibilityLabel(settings.t("outcomeStatus", ["status": settings.t(statusKey(for: outcome.status))]))
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
                        .pathContextMenu(outcome.path)
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

    /// Reuses the shared cleanup vocabulary so both result sheets read alike.
    private func statusKey(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "deleted"
        case .purged: "deleted"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }
}