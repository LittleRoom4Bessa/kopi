import KopiCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathPickers
            Divider()

            switch state.phase {
            case .idle:
                idleSection
            case .running:
                progressSection
            case .finished(let report):
                resultSection(report)
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit kopi") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: Path pickers

    private var pathPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiskCardView(
                title: "Source (SD card)",
                path: state.sourcePath,
                available: state.sourceAvailable,
                descriptor: state.sourceDisk,
                probe: state.probeStates["source"] ?? .idle,
                probeLabel: (state.probeStates["source"] ?? .idle).doneLabel(isSource: true),
                onChoose: state.pickSource,
                onProbe: state.probeSource
            )
            DiskCardView(
                title: "Destination",
                path: state.destinationPath,
                available: state.destinationAvailable,
                descriptor: state.destinationDisk,
                probe: state.probeStates["destination"] ?? .idle,
                probeLabel: (state.probeStates["destination"] ?? .idle).doneLabel(isSource: false),
                onChoose: state.pickDestination,
                onProbe: state.probeDestination
            )
        }
    }

    // MARK: Idle / pre-copy summary

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = state.plan {
                Text("\(plan.fileCount) files · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                    .font(.headline)
            } else {
                Text("Select source and destination to begin.")
                    .foregroundStyle(.secondary)
            }
            Button("Start") { state.start() }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canStart)
            Button("Pro Mode…") { state.openProPanel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Live progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = state.progress {
                ProgressView(value: Double(progress.bytesCompleted), total: Double(max(progress.totalBytes, 1)))
                Text(progress.currentFile)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(progress.filesCompleted)/\(progress.totalFiles) files · \(ByteCountFormatter.string(fromByteCount: progress.bytesCompleted, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                // Condensed per-destination summary during pro sessions.
                if progress.destinations.count > 1 {
                    ForEach(progress.destinations, id: \.root) { dest in
                        HStack {
                            Text(dest.root.lastPathComponent).font(.caption2).lineLimit(1)
                            Spacer()
                            switch dest.state {
                            case .active:
                                Text("\(dest.filesFinished) files").font(.caption2).foregroundStyle(.secondary)
                            case .done:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                            case .stopped(let reason):
                                Text(reason.userMessage).font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Result

    private func resultSection(_ report: SessionReport) -> some View {
        // Casual mode always has exactly one destination.
        let dest = report.primaryDestination
        return VStack(alignment: .leading, spacing: 8) {
            if report.succeeded {
                Label("Backup verified — safe to eject the card.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Backup not complete — do NOT format the card.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if let abort = report.abortReason ?? dest?.abortReason {
                    Text(abort.userMessage).font(.callout).foregroundStyle(.red)
                }
            }

            Text(summaryLine(report)).font(.caption).foregroundStyle(.secondary)

            if let dest, !dest.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(dest.failed, id: \.relativePath) { failure in
                            Text("✗ \(failure.relativePath) — \(failure.reason.userMessage)")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Button("Reveal in Finder") { state.revealDestination() }
                Spacer()
                Button("New Session") { state.reset() }
            }
        }
    }

    private func summaryLine(_ report: SessionReport) -> String {
        guard let dest = report.primaryDestination else { return "" }
        var parts = ["\(dest.copied.count) copied"]
        if !dest.verifiedSkipped.isEmpty { parts.append("\(dest.verifiedSkipped.count) already verified") }
        if !dest.failed.isEmpty { parts.append("\(dest.failed.count) failed") }
        if let manifest = dest.manifestURL { parts.append("manifest: \(manifest.lastPathComponent)") }
        return parts.joined(separator: " · ")
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
