import KopiCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pathPickers
            Divider()

            switch state.phase {
            case .idle:
                idleSection
                    .transition(.opacity)
            case .running:
                ProgressSectionView(progress: state.progress)
                    .transition(.opacity)
            case .finished(let report):
                ResultSectionView(report: report,
                                  onReveal: state.revealDestination,
                                  onReset: state.reset)
                    .transition(.opacity)
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
        .animation(.smooth(duration: 0.2), value: state.phase)
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
            HStack {
                Button("Start") { state.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canStart)
                    .accessibilityHint("Copies and verifies all files to the destination")
                Button("Pro Mode…") { openWindow(id: "pro") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Opens the 3-2-1 backup panel with three destinations")
            }
        }
    }
}

/// Live progress — its own view type so per-file updates only re-evaluate
/// this subtree, not the whole popover (view-structure guidance).
private struct ProgressSectionView: View {
    let progress: CopyProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                ProgressView(
                    value: Double(progress.bytesCompleted),
                    total: Double(max(progress.totalBytes, 1))
                )
                Text(progress.currentFile)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(progress.filesCompleted)/\(progress.totalFiles) files · \(bytes(progress.bytesCompleted)) of \(bytes(progress.totalBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                // Condensed per-destination summary during pro sessions.
                if progress.destinations.count > 1 {
                    ForEach(progress.destinations, id: \.root) { dest in
                        DestinationProgressRow(progress: dest)
                    }
                }
            } else {
                ProgressView()
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// One line of condensed per-destination progress (popover and pro panel).
struct DestinationProgressRow: View {
    let progress: DestinationProgress

    var body: some View {
        HStack {
            Text(progress.root.lastPathComponent).font(.caption2).lineLimit(1)
            Spacer()
            switch progress.state {
            case .active:
                Text("\(progress.filesFinished) files")
                    .font(.caption2).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption2)
            case .stopped(let reason):
                Text(reason.userMessage).font(.caption2).foregroundStyle(.red)
            }
            if progress.filesFailed > 0 {
                Text("\(progress.filesFailed) failed")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Session result — separate invalidation boundary from the running state.
private struct ResultSectionView: View {
    let report: SessionReport
    let onReveal: () -> Void
    let onReset: () -> Void

    var body: some View {
        // Casual mode always has exactly one destination.
        let dest = report.primaryDestination
        VStack(alignment: .leading, spacing: 8) {
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

            Text(summaryLine).font(.caption).foregroundStyle(.secondary)

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
                Button("Reveal in Finder", action: onReveal)
                Spacer()
                Button("New Session", action: onReset)
            }
        }
    }

    private var summaryLine: String {
        guard let dest = report.primaryDestination else { return "" }
        var parts = ["\(dest.copied.count) copied"]
        if !dest.verifiedSkipped.isEmpty { parts.append("\(dest.verifiedSkipped.count) already verified") }
        if !dest.failed.isEmpty { parts.append("\(dest.failed.count) failed") }
        if let manifest = dest.manifestURL { parts.append("manifest: \(manifest.lastPathComponent)") }
        return parts.joined(separator: " · ")
    }
}
