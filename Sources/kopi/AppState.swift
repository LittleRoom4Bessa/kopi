import AppKit
import Foundation
import KopiCore
import SwiftUI
import UserNotifications

enum SessionPhase: Equatable {
    case idle
    case running
    case finished(SessionReport)
}

/// Single source of truth, observed with fine granularity via @Observable
/// (macOS 14+; replaces ObservableObject/@Published per state-management guidance).
@Observable
@MainActor
final class AppState {

    // MARK: Persisted selections (plain paths; non-sandboxed personal tool)

    var sourcePath: String {
        didSet { UserDefaults.standard.set(sourcePath, forKey: "sourcePath") }
    }
    var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: "destinationPath") }
    }
    /// Pro mode: 3 destination folders, hash choice, strict toggle (pro-mode spec).
    var proSettings: ProSettings {
        didSet {
            if let data = try? JSONEncoder().encode(proSettings) {
                UserDefaults.standard.set(data, forKey: "proSettings")
            }
            refreshProDescriptors()
        }
    }

    // MARK: Session state

    var plan: CopyPlan?
    var phase: SessionPhase = .idle
    var progress: CopyProgress?

    // MARK: Disk intelligence

    enum ProbeState: Equatable {
        case idle
        case running
        case done(ProbeResult)
        case failed(String)
    }

    var sourceDisk: DiskDescriptor?
    var destinationDisk: DiskDescriptor?
    /// Keyed "source", "destination", "pro0"…"pro2".
    var probeStates: [String: ProbeState] = [:]
    /// Pro mode: one descriptor per destination slot.
    var proDisks: [DiskDescriptor?] = Array(repeating: nil, count: ProSettings.destinationCount)
    var proViolations: [RuleViolation] = []
    private var probeTasks: [String: Task<Void, Never>] = [:]

    private var engine = CopyEngine()

    var sourceAvailable: Bool {
        !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath)
    }
    var destinationAvailable: Bool {
        !destinationPath.isEmpty && FileManager.default.fileExists(atPath: destinationPath)
    }
    var canStart: Bool {
        sourceAvailable && destinationAvailable && plan != nil && phase != .running
    }

    init() {
        sourcePath = UserDefaults.standard.string(forKey: "sourcePath") ?? ""
        destinationPath = UserDefaults.standard.string(forKey: "destinationPath") ?? ""
        if let data = UserDefaults.standard.data(forKey: "proSettings"),
           let settings = try? JSONDecoder().decode(ProSettings.self, from: data) {
            proSettings = settings
        } else {
            proSettings = ProSettings()
        }
        requestNotificationAuthorization()
        refreshPlan()
    }

    // MARK: Folder pickers

    func pickSource() { pickFolder { self.sourcePath = $0 } }
    func pickDestination() { pickFolder { self.destinationPath = $0 } }
    func pickProDestination(slot: Int) {
        pickFolder { [weak self] path in
            self?.proSettings.destinations[slot] = path
        }
    }

    private func pickFolder(assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            assign(url.path)
            refreshPlan()
        }
    }

    // MARK: Plan + session

    /// Rebuilds the pre-copy summary. Must be cheap enough to call on every change.
    func refreshPlan() {
        if sourceAvailable, destinationAvailable {
            let source = URL(fileURLWithPath: sourcePath)
            let destination = URL(fileURLWithPath: destinationPath)
            plan = try? SourceEnumerator.plan(source: source, destination: destination)
        } else {
            plan = nil
        }
        refreshDiskDescriptors()
    }

    /// Characterize source + casual destination off the main thread; missing
    /// metadata never blocks selection (disk-intelligence spec).
    private func refreshDiskDescriptors() {
        let source = sourcePath, destination = destinationPath
        let work = Task.detached { () -> (DiskDescriptor?, DiskDescriptor?) in
            let sourceDisk = source.isEmpty ? nil : DiskInspector.inspect(path: URL(fileURLWithPath: source))
            let destinationDisk = destination.isEmpty ? nil : DiskInspector.inspect(path: URL(fileURLWithPath: destination))
            return (sourceDisk, destinationDisk)
        }
        Task { [weak self] in
            let (sourceDisk, destinationDisk) = await work.value
            self?.sourceDisk = sourceDisk
            self?.destinationDisk = destinationDisk
            self?.evaluateProRules()
        }
        refreshProDescriptors()
    }

    /// Pro mode: characterize all 3 destination slots, then re-evaluate rules.
    private func refreshProDescriptors() {
        let paths = proSettings.destinations
        let work = Task.detached { () -> [DiskDescriptor?] in
            paths.map { path in
                path.isEmpty ? nil : DiskInspector.inspect(path: URL(fileURLWithPath: path))
            }
        }
        Task { [weak self] in
            let descriptors = await work.value
            self?.proDisks = descriptors
            self?.evaluateProRules()
        }
    }

    private func evaluateProRules() {
        let descriptors = proDisks.compactMap { $0 }
        proViolations = MediaRules.evaluate(source: sourceDisk, destinations: descriptors)
    }

    // MARK: Pro mode gating (design D6)

    var proSlotsFilled: Bool {
        proSettings.destinations.allSatisfy {
            !$0.isEmpty && FileManager.default.fileExists(atPath: $0)
        }
    }
    func proSlotAvailable(_ slot: Int) -> Bool {
        let path = proSettings.destinations[slot]
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
    var canStartPro: Bool {
        sourceAvailable && proSlotsFilled && phase != .running
            && MediaRules.canStart(violations: proViolations, strictMode: proSettings.strictMode)
    }

    // MARK: Speed probe (explicit, cancellable — design D2)

    func probeSource() { toggleProbe(key: "source", path: sourcePath, isSourceRole: true) }
    func probeDestination() { toggleProbe(key: "destination", path: destinationPath, isSourceRole: false) }
    func probeProDestination(slot: Int) {
        toggleProbe(key: "pro\(slot)", path: proSettings.destinations[slot], isSourceRole: false)
    }

    private func toggleProbe(key: String, path: String, isSourceRole: Bool) {
        if probeTasks[key] != nil {
            probeTasks[key]?.cancel()
            probeTasks[key] = nil
            probeStates[key] = .idle
            return
        }
        guard !path.isEmpty else { return }
        probeStates[key] = .running

        // Detached work captures only value types; results hop back via a
        // MainActor-inheriting wrapper task (Swift 6 sending rules).
        let work = Task.detached { () -> ProbeResult in
            let url = URL(fileURLWithPath: path)
            return isSourceRole
                ? try SpeedProbe.probeSource(at: url) { Task.isCancelled }
                : try SpeedProbe.probeDestination(at: url) { Task.isCancelled }
        }
        probeTasks[key] = Task { [weak self] in
            defer { self?.probeTasks[key] = nil }
            do {
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.probeStates[key] = .done(result)
            } catch is SpeedProbeError {
                self?.probeStates[key] = .idle
            } catch {
                if Task.isCancelled { self?.probeStates[key] = .idle }
                else { self?.probeStates[key] = .failed(error.localizedDescription) }
            }
        }
    }

    nonisolated static func probeLabel(_ result: ProbeResult, isSource: Bool) -> String {
        func mbps(_ bps: Double) -> String { String(format: "%.0f MB/s", bps / 1_000_000) }
        if isSource {
            return result.readBytesPerSecond.map { "measured read \(mbps($0))" } ?? "no measurable file"
        }
        switch (result.writeBytesPerSecond, result.readBytesPerSecond) {
        case let (w?, r?): return "measured \(mbps(w)) write · \(mbps(r)) read"
        case let (w?, nil): return "measured write \(mbps(w))"
        case let (nil, r?): return "measured read \(mbps(r))"
        default: return "no result"
        }
    }

    // MARK: Sessions

    func start() {
        guard let plan else { return }
        runSession(plan: plan)
    }

    /// Pro mode: 3 destinations, selected hash algorithm.
    func startPro() {
        guard canStartPro else { return }
        let source = URL(fileURLWithPath: sourcePath)
        let dests = proSettings.destinations.map { URL(fileURLWithPath: $0) }
        guard let plan = try? SourceEnumerator.plan(
            source: source, destinations: dests, algorithm: proSettings.algorithm
        ) else { return }
        runSession(plan: plan)
    }

    private func runSession(plan: CopyPlan) {
        phase = .running
        progress = nil
        let engine = self.engine
        Task.detached {
            let report = engine.run(plan: plan) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            await MainActor.run {
                self.progress = nil
                self.phase = .finished(report)
                self.sendCompletionNotification(report)
            }
        }
    }

    func reset() {
        phase = .idle
        refreshPlan()
    }

    // MARK: Completion

    func revealDestination() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destinationPath)
    }

    private func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return } // running unbundled (swift run)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendCompletionNotification(_ report: SessionReport) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        if report.succeeded {
            let verified = report.destinations.reduce(0) { $0 + $1.copied.count + $1.verifiedSkipped.count }
            content.title = "kopi: backup verified ✅"
            if report.destinations.count > 1 {
                content.body = "\(report.destinations.count) destinations verified (\(report.algorithm.displayName)). Safe to eject the card."
            } else {
                content.body = "\(verified) files verified. Safe to eject the card."
            }
        } else if let abort = report.abortReason {
            content.title = "kopi: backup interrupted"
            content.body = abort.userMessage
        } else {
            let stopped = report.destinations.compactMap(\.abortReason)
            let failed = report.destinations.reduce(0) { $0 + $1.failed.count }
            content.title = "kopi: backup finished with errors"
            if let first = stopped.first {
                content.body = first.userMessage
            } else {
                content.body = "\(failed) file(s) failed verification."
            }
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension AppState.ProbeState {
    func doneLabel(isSource: Bool) -> String {
        if case .done(let result) = self {
            return AppState.probeLabel(result, isSource: isSource)
        }
        return ""
    }
}
