import AppKit
import Foundation

/// Checks GitHub Releases for a newer version, surfaces its notes, and installs it (download → verify
/// → swap the app bundle → relaunch). Dependency-free; the release it installs is built + signed by
/// `release.yml`. Because releases share a stable signing identity, the upgraded app keeps its macOS
/// Accessibility/Keychain grants.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String   // tag without the leading "v", e.g. "1.2.0"
        let notes: String     // markdown (the GitHub release body / CHANGELOG section)
        let zipURL: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case noAppInArchive, bundleMismatch
        var errorDescription: String? {
            switch self {
            case .noAppInArchive: return "The downloaded update didn't contain an app."
            case .bundleMismatch:  return "The downloaded app isn't RewriteDB."
            }
        }
    }

    @Published private(set) var status: Status = .idle

    private let repo = "danb235/rewritedb"
    private static let lastCheckKey = "updater.lastCheckAt"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Check

    /// Auto-check at most once per 24h; failures are silent (no nagging on a flaky network).
    func checkOnLaunchIfDue() {
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: Self.lastCheckKey) > 86_400 else { return }
        check(force: false)
    }

    func check(force: Bool) {
        switch status { case .checking, .downloading: return; default: break }
        status = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task {
            do {
                if let release = try await fetchLatest(), Updater.isNewer(release.version, than: currentVersion) {
                    status = .available(release)
                } else {
                    status = .upToDate
                }
            } catch {
                status = force ? .failed(error.localizedDescription) : .idle   // silent on auto-check
            }
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = zip["browser_download_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (obj["body"] as? String) ?? "", zipURL: url)
    }

    /// Numeric dot/dash compare (ignores any pre-release suffix). True if `remote` is newer.
    static func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }
        }
        let r = parts(remote), c = parts(current)
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Install

    func install() {
        guard case .available(let release) = status else { return }
        status = .downloading
        Task {
            do { try await performInstall(release) }       // terminates the app on success
            catch { status = .failed(error.localizedDescription) }
        }
    }

    private func performInstall(_ release: Release) async throws {
        let (tmpZip, _) = try await URLSession.shared.download(from: release.zipURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rdb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmpZip, to: zipPath)

        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path])
        guard let newApp = try FileManager.default
            .contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInArchive }

        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])   // integrity
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.bundleMismatch
        }
        try swapAndRelaunch(newApp: newApp)
    }

    /// Replaces the running bundle and relaunches, via a detached shell that waits for us to exit
    /// (a bundle can't be swapped while its process holds it). Backs up + rolls back on failure.
    private func swapAndRelaunch(newApp: URL) throws {
        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        func q(_ p: String) -> String { "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = dest.path + ".old"
        let script = """
        #!/bin/bash
        while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/mv \(q(dest.path)) \(q(old)) || exit 1
        if /bin/mv \(q(newApp.path)) \(q(dest.path)); then
          /bin/rm -rf \(q(old))
        else
          /bin/mv \(q(old)) \(q(dest.path))
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path)) 2>/dev/null
        /usr/bin/open \(q(dest.path))
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdb-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()   // detached — survives our termination
        NSApplication.shared.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "Updater", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed: \(output)"])
        }
        return output
    }
}
