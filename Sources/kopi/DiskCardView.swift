import KopiCore
import SwiftUI

/// One volume summarized as a "disk card": name, type, bus, capacity,
/// interface ceiling, and an on-demand measured speed (design D2/D7).
struct DiskCardView: View {
    let title: String
    let path: String
    let available: Bool
    let descriptor: DiskDescriptor?
    let probe: AppState.ProbeState
    let probeLabel: String
    let onChoose: () -> Void
    let onProbe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…", action: onChoose)
            }

            if path.isEmpty {
                Text("Not set").foregroundStyle(.tertiary)
            } else {
                if let descriptor {
                    descriptorSection(descriptor)
                } else {
                    Text(abbreviated(path)).lineLimit(1).truncationMode(.middle)
                }
                if !available {
                    Text("⚠ unavailable").foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func descriptorSection(_ d: DiskDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(d.volumeName ?? abbreviated(path))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("·")
                Text("\(d.type.displayName) · \(d.bus.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let total = d.totalBytes, let free = d.freeBytes {
                CapacityBar(used: total - free, total: total)
                Text("\(format(free)) free of \(format(total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(d.interfaceSpeedLabel).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                probeControl
            }

            Text(abbreviated(path)).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var probeControl: some View {
        switch probe {
        case .idle:
            Button("Speed Test", action: onProbe).controlSize(.small)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Button("Cancel", action: onProbe).controlSize(.small)
            }
        case .done:
            HStack(spacing: 4) {
                Text(probeLabel).font(.caption).lineLimit(1).truncationMode(.tail)
                Button("Retest", action: onProbe).controlSize(.mini)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Retry", action: onProbe).controlSize(.mini)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct CapacityBar: View {
    let used: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary)
                    .frame(width: geo.size.width * min(max(Double(used) / Double(max(total, 1)), 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(Int(Double(used) / Double(max(total, 1)) * 100)) percent used")
    }
}
