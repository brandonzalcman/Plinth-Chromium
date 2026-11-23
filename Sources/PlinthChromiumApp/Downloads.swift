import AppKit
import Observation
import PlinthBarUI
import PlinthCEF
import PlinthModel

/// What Chromium reports about one download, in plain values (so the list logic can be tested).
struct DownloadUpdate: Equatable {
    var id: UInt32
    var url: String
    var filename: String
    var path: String
    var receivedBytes: Int64
    var totalBytes: Int64?
    var bytesPerSecond: Int64
    var isInProgress: Bool
    var isComplete: Bool
    var isCanceled: Bool
    var isInterrupted: Bool

    init(id: UInt32, url: String = "", filename: String, path: String = "", receivedBytes: Int64 = 0, totalBytes: Int64? = nil,
         bytesPerSecond: Int64 = 0, isInProgress: Bool = true, isComplete: Bool = false, isCanceled: Bool = false,
         isInterrupted: Bool = false) {
        self.id = id; self.url = url; self.filename = filename; self.path = path; self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond; self.isInProgress = isInProgress
        self.isComplete = isComplete; self.isCanceled = isCanceled; self.isInterrupted = isInterrupted
    }

    init(_ d: PCEFDownload) {
        self.init(id: d.identifier, url: d.url, filename: d.filename, path: d.path, receivedBytes: d.receivedBytes,
                  totalBytes: d.totalBytes >= 0 ? d.totalBytes : nil, bytesPerSecond: d.bytesPerSecond,
                  isInProgress: d.isInProgress, isComplete: d.isComplete, isCanceled: d.isCanceled, isInterrupted: d.isInterrupted)
    }
}

/// The downloads of this session, newest first, in the shared `DownloadItem` form the tray and bar draw.
struct DownloadList: Equatable {
    private(set) var items: [DownloadItem] = []
    /// Chromium's id for each item.
    private(set) var chromiumIDs: [UUID: UInt32] = [:]

    mutating func apply(_ u: DownloadUpdate, now: Date = Date()) {
        let state: DownloadItem.State = u.isComplete ? .finished
            : u.isCanceled ? .cancelled
            : u.isInterrupted ? .failed("The download was interrupted.")
            : .running
        let progress: Double? = u.isComplete ? 1 : u.totalBytes.map { $0 > 0 ? min(Double(u.receivedBytes) / Double($0), 1) : 0 }
        if let i = items.firstIndex(where: { chromiumIDs[$0.id] == u.id }) {
            var item = items[i]
            item.state = state
            item.progress = progress
            item.receivedBytes = u.receivedBytes
            item.totalBytes = u.totalBytes
            item.bytesPerSecond = state == .running && u.bytesPerSecond > 0 ? Double(u.bytesPerSecond) : nil
            if !u.path.isEmpty { item.fileURL = URL(fileURLWithPath: u.path); item.filename = item.fileURL!.lastPathComponent }
            items[i] = item
        } else {
            let item = DownloadItem(filename: u.filename, progress: progress, state: state,
                                    fileURL: u.path.isEmpty ? nil : URL(fileURLWithPath: u.path), startedAt: now,
                                    receivedBytes: u.receivedBytes, totalBytes: u.totalBytes, sourceURL: URL(string: u.url))
            chromiumIDs[item.id] = u.id
            items.insert(item, at: 0)
        }
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        chromiumIDs[id] = nil
    }

    /// Drops everything that has stopped; running downloads stay.
    mutating func clearFinished() {
        for item in items where item.state != .running { chromiumIDs[item.id] = nil }
        items.removeAll { $0.state != .running }
    }

    var running: [DownloadItem] { items.filter { $0.state == .running } }

    /// What the bar's downloads button shows.
    var barState: BarDownloadsState? {
        guard !items.isEmpty else { return nil }
        let known = running.compactMap(\.progress)
        return BarDownloadsState(runningCount: running.count,
                                 progress: known.isEmpty ? nil : min(max(known.reduce(0, +) / Double(known.count), 0), 1))
    }
}

/// The app's downloads, fed by Chromium and shown in the dock, the sidebar and the downloads tray.
@MainActor
@Observable
final class DownloadsModel {
    private(set) var list = DownloadList()
    /// The last download to finish, briefly, for a little celebration in the chrome.
    private(set) var justFinished: UUID?
    /// A download from this address has stopped (finished, cancelled or failed).
    @ObservationIgnored var onStopped: (URL) -> Void = { _ in }
    /// "Open safe files after downloading" is on.
    @ObservationIgnored var opensSafeFiles: () -> Bool = { false }

    init() {
        PCEFRuntime.downloadHandler = { [weak self] download in
            MainActor.assumeIsolated { self?.update(DownloadUpdate(download)) }
        }
    }

    private func update(_ u: DownloadUpdate) {
        let known = list.items.first { list.chromiumIDs[$0.id] == u.id }
        let before = known?.state
        list.apply(u)
        if before == .running || known == nil, !u.isInProgress, let url = URL(string: u.url) { onStopped(url) }
        if before != .finished, u.isComplete, opensSafeFiles(),
           let file = list.items.first(where: { list.chromiumIDs[$0.id] == u.id })?.fileURL,
           DownloadSafety.isSafeToOpen(filename: file.lastPathComponent) {
            NSWorkspace.shared.open(file)
        }
        if before == .running, u.isComplete, let item = list.items.first(where: { list.chromiumIDs[$0.id] == u.id }) {
            justFinished = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.justFinished == item.id { self?.justFinished = nil }
            }
        }
    }

    func open(_ id: UUID) {
        guard let url = list.items.first(where: { $0.id == id })?.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ id: UUID) {
        guard let url = list.items.first(where: { $0.id == id })?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func cancel(_ id: UUID) {
        if let chromium = list.chromiumIDs[id] { PCEFRuntime.cancelDownload(chromium) }
    }

    /// "Ask where to save each file": a save panel with the name Plinth would use. `decide` gets the
    /// chosen path, or nil when the panel is cancelled (which cancels the download).
    static func chooseSaveLocation(suggested: String, decide: @escaping (String?) -> Void) {
        let suggestedURL = URL(fileURLWithPath: suggested)
        let panel = NSSavePanel()
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.activate()
        // A panel of its own: a sheet on the browser window would sit under the page's window.
        panel.begin { response in
            guard response == .OK, let chosen = panel.url else { decide(nil); return }
            // The panel already confirmed replacing a file that is there.
            try? FileManager.default.removeItem(at: chosen)
            decide(chosen.path)
        }
    }

    func remove(_ id: UUID) { list.remove(id) }
    func clear() { list.clearFinished() }
}
