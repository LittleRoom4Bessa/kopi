import KopiCore
import SwiftUI

/// Pro mode: 3-2-1 ingest — 3 destination folders, hash choice, media rules.
/// Expands the popover in place (no separate window). Collapsing mid-session
/// never stops it — the collapsed popover keeps showing condensed progress.
struct ProModeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                destinationsSection
                Divider()
                verificationSection
                Divider()
                rulesSection
                Divider()
                actionSection
            }
        }
        .frame(maxHeight: 520)
    }

    // MARK: Destinations

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3 copies · 2 media · 1 remote")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<ProSettings.destinationCount, id: \.self) { slot in
                DestinationSlotCard(slot: slot)
            }
        }
    }

    // MARK: Verification

    private var verificationSection: some View {
        @Bindable var state = state
        return HStack(alignment: .center, spacing: 16) {
            Picker("Verify with", selection: $state.proSettings.algorithm) {
                ForEach([HashAlgorithm.xxh64, .sha256], id: \.self) { algorithm in
                    Text("\(algorithm.displayName) — \(algorithm.subtitle)").tag(algorithm)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("Hash algorithm used to verify every copied file")

            Toggle("Strict 3-2-1 mode", isOn: $state.proSettings.strictMode)
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
                    .accessibilityHint("Copies the source to all three destinations with verification")
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
                        DestinationProgressRow(progress: dest)
                    }
                } else {
                    ProgressView()
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                }

            case .finished(let report):
                ForEach(report.destinations, id: \.root) { dest in
                    DestinationResultRow(report: dest)
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
}

/// One pro destination slot: disk card + chooser + speed probe.
private struct DestinationSlotCard: View {
    @Environment(AppState.self) private var state
    let slot: Int

    var body: some View {
        DiskCardView(
            title: "Destination \(slot + 1)",
            path: state.proSettings.destinations[slot],
            available: state.proSlotAvailable(slot),
            descriptor: state.proDisks[slot],
            probe: state.probeStates["pro\(slot)"] ?? .idle,
            probeLabel: (state.probeStates["pro\(slot)"] ?? .idle).doneLabel(isSource: false),
            onChoose: { state.pickProDestination(slot: slot) },
            onProbe: { state.probeProDestination(slot: slot) }
        )
    }
}

/// One line of per-destination results (pro mode).
struct DestinationResultRow: View {
    let report: DestinationReport

    var body: some View {
        HStack {
            Text(report.root.lastPathComponent).font(.caption).lineLimit(1)
            Spacer()
            if let abort = report.abortReason {
                Text(abort.userMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text("\(report.copied.count) copied · \(report.verifiedSkipped.count) verified · \(report.failed.count) failed")
                    .font(.caption)
                    .foregroundStyle(report.failed.isEmpty ? Color.secondary : Color.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
