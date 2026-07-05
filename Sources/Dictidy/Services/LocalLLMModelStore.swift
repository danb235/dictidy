import Foundation

/// Manages the single local rewrite model (`Qwen3-4B-Instruct-2507`, Q4_K_M, ~2.5 GB). Mirrors
/// `WhisperModelStore`: the app downloads and owns its own copy under Application Support — it does
/// not reuse any other app's cache, so a fresh install works for anyone. No model picker: one model,
/// one location. Downloaded only when the user opts into the local provider — a Claude-only user
/// never fetches it.
@MainActor
final class LocalLLMModelStore: NSObject {
    typealias Status = ModelStatus

    /// Called on the main actor whenever `status` changes, so `AppState` can mirror it into a
    /// `@Published` property for SwiftUI.
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .missing {
        didSet { onStatusChange?(status) }
    }

    nonisolated static let modelFilename = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    /// Human-readable name shown in the UI and recorded in history.
    nonisolated static let modelDisplayName = "Qwen3-4B-Instruct (local)"
    // The official Qwen repo is gated (401); unsloth's mirror of the same GGUF is public.
    private static let remoteURL = URL(
        string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/\(modelFilename)")!
    /// Real file is ~2,497,281,120 bytes; a 2 GB floor rejects truncated/partial files.
    private static let minValidBytes: Int64 = 2_000_000_000
    private static let requiredFreeBytes: Int64 = 3_000_000_000

    private var downloadTask: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    var isReady: Bool { if case .ready = status { return true }; return false }

    var modelsDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return base.appendingPathComponent("Dictidy/models", isDirectory: true)
    }

    var modelURL: URL? { modelsDirectory?.appendingPathComponent(Self.modelFilename) }

    /// Cheap check at launch: is the model already present?
    func resolve() {
        guard let url = modelURL else { status = .failed("Can't locate Application Support."); return }
        if fileIsValid(url) {
            status = .ready(url)
        } else if case .downloading = status {
            // leave an in-flight download alone
        } else {
            status = .missing
        }
    }

    func download() {
        if case .downloading = status { return }
        guard let dir = modelsDirectory, let dest = modelURL else {
            status = .failed("Can't locate Application Support."); return
        }
        if freeBytes(at: dir) < Self.requiredFreeBytes {
            status = .failed("Not enough free disk space — the model needs about 3 GB.")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = dest // dir ensured; destination path used in the delegate
        status = .downloading(0)
        let task = session.downloadTask(with: Self.remoteURL)
        downloadTask = task
        task.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        status = fileIsValid(modelURL) ? .ready(modelURL!) : .missing
    }

    // MARK: - Helpers

    private func fileIsValid(_ url: URL?) -> Bool {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= Self.minValidBytes
    }

    private func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
    }

    fileprivate func setStatus(_ newStatus: Status) {
        status = newStatus
    }
}

extension LocalLLMModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.setStatus(.downloading(min(progress, 0.999))) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Runs on the delegate queue (off main). Move synchronously — `location` is deleted after
        // this returns. Copy to a same-dir .partial (may cross volumes), then atomically rename.
        let fm = FileManager.default
        guard let final = modelURLNonisolated() else {
            Task { @MainActor in self.setStatus(.failed("Can't locate Application Support.")) }
            return
        }
        let partial = final.appendingPathExtension("partial")
        do {
            try? fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: location, to: partial)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            Task { @MainActor in self.setStatus(.ready(final)) }
        } catch {
            try? fm.removeItem(at: partial)
            Task { @MainActor in self.setStatus(.failed("Couldn't save the model: \(error.localizedDescription)")) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }                       // success already handled above
        if (error as NSError).code == NSURLErrorCancelled { return }   // user cancel → cancel() set status
        Task { @MainActor in self.setStatus(.failed("Download failed: \(error.localizedDescription)")) }
    }

    /// Path resolution usable from the nonisolated delegate (no main-actor state touched).
    nonisolated private func modelURLNonisolated() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return base.appendingPathComponent("Dictidy/models/\(Self.modelFilename)", isDirectory: false)
    }
}
