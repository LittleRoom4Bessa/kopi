import KopiCore
import SwiftUI

/// Pro mode: 3-2-1 ingest — 3 destination folders, hash choice, media rules.
/// Lives in a detached panel (design D7); closing the panel never stops a
/// running session — the popover keeps showing condensed progress.
struct ProPanelView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sourceSection
                Divider()
                destinationsSection
                Divider()
                verificationSection
                Divider()
                rulesSection
                Divider()
                actionSection
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = state.sourceDisk {
                HStack(spacing: 6) {
                    Image(systemName: "sdcard")
                    Text(source.volumeName ?? URL(fileURLWithPath: state.sourcePath).lastPathComponent)
                        .font(.headline)
                    Text("·")
                    Text("\(source.type.displayName) · \(source.bus.displayName)")
                        .foregroundStyle(.secondary)
                }
                if let total = source.totalBytes, let free = source.freeBytes {
                    Text("\(format(total - free)) used of \(format(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Pick a source in the menu bar popover first.", systemImage: "sdcard")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Destinations

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3 copies · 2 media · 1 remote")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<ProSettings.destinationCount, id: \.self) { slot in
                DiskCardView(
                    title: "Destination \(slot + 1)",
                    path: state.proSettings.destinations[slot],
                    available: !state.proSettings.destinations[slot].isEmpty
                        && FileManager.default.fileExists(atPath: state.proSettings.destinations[slot]),
                    descriptor: state.proDisks[slot],
                    probe: state.probeStates["pro\(slot)"] ?? .idle,
                    probeLabel: (state.probeStates["pro\(slot)"] ?? .idle).doneLabel(isSource: false),
                    onChoose: { state.pickProDestination(slot: slot) },
                    onProbe: { state.probeProDestination(slot: slot) }
                )
            }
        }
    }

    // MARK: Verification

    private var verificationSection: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("Verify with", selection: Binding(
                get: { state.proSettings.algorithm },
                set: { state.proSettings.algorithm = $0 }
            )) {
                ForEach([HashAlgorithm.xxh64, .sha256], id: \.self) { algorithm in
                    Text("\(algorithm.displayName) — \(algorithm.subtitle)").tag(algorithm)
                }
            }
            .frame(maxWidth: 280)

            Toggle("Strict 3-2-1 mode", isOn: Binding(
                get: { state.proSettings.strictMode },
                set: { state.proSettings.strictMode = $0 }
            ))
            .help("Block Start when media-diversity rules are violated")
        }
    }

    // MARK: Rules

    @ViewBuilder
    private var rulesSection: some View {
        if state.proViolations.isEmpty {
            if state.proSlotsFilled {
                Label("3-2-1 rules satisfied", systemImage: "checkmark.shield")
                    .foregroundStyle(.green).font(.callout)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.proViolations, id: \.userMessage) { violation in
                    Label(violation.userMessage,
                          systemImage: violation.isHardError
                            ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(violation.isHardError ? Color.red : Color.orange)
                }
            }
        }
    }

    // MARK: Action / session

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .idle:
                Button("Start 3-2-1 Backup") { state.startPro() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canStartPro)
                if !state.proSlotsFilled {
                    Text("Assign all 3 destinations to start.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !state.canStartPro {
                    Text(state.proSettings.strictMode
                         ? "Strict mode: resolve the violations above to start."
                         : "Resolve the errors above to start.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .running:
                if let progress = state.progress {
                    ProgressView(
                        value: Double(progress.bytesCompleted),
                        total: Double(max(progress.totalBytes, 1))
                    )
                    ForEach(progress.destinations, id: \.root) { dest in
                        destinationProgressRow(dest)
                    }
                } else {
                    ProgressView()
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                }

            case .finished(let report):
                ForEach(report.destinations, id: \.root) { dest in
                    destinationResultRow(dest)
                }
                if report.succeeded {
                    Label("All destinations verified — safe to eject the card.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not fully verified — do NOT format the card.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    if let abort = report.abortReason {
                        Text(abort.userMessage).font(.callout).foregroundStyle(.red)
                    }
                }
                Button("New Session") { state.reset() }
            }
        }
    }

    private func destinationProgressRow(_ dest: DestinationProgress) -> some View {
        HStack {
            Text(dest.root.lastPathComponent).font(.caption).lineLimit(1)
            Spacer()
            switch dest.state {
            case .active:
                Text("\(dest.filesFinished) files").font(.caption).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .stopped(let reason):
                Text(reason.userMessage).font(.caption).foregroundStyle(.red)
            }
            if dest.filesFailed > 0 {
                Text("\(dest.filesFailed) failed").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func destinationResultRow(_ dest: DestinationReport) -> some View {
        HStack {
            Text(dest.root.lastPathComponent).font(.caption).lineLimit(1)
            Spacer()
            if let abort = dest.abortReason {
                Text(abort.userMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text("\(dest.copied.count) copied · \(dest.verifiedSkipped.count) verified · \(dest.failed.count) failed")
                    .font(.caption)
                    .foregroundStyle(dest.failed.isEmpty ? Color.secondary : Color.orange)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
