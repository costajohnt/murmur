import Foundation

/// Opt-in check for a newer GitHub release (`AppSettings.checkForUpdates`,
/// default off): one GET to the GitHub releases API, at most once a day,
/// carrying no dictation data. Failures are logged and otherwise silent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// Set when the latest release is newer than this build.
    @Published private(set) var available: Release?

    static let latestURL = URL(string: "https://api.github.com/repos/costajohnt/murmur/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    private init() {}

    /// Check now if enabled and the last check is over a day old, and keep
    /// re-checking hourly so a Mac that stays up for days still notices.
    func start() {
        checkIfDue()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard AppSettings.checkForUpdates else {
            available = nil
            return
        }
        let last = AppSettings.defaults.object(forKey: AppSettings.lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await check() }
    }

    private struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: URL
    }

    private nonisolated static func ephemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// Stamps the daily check only once GitHub answered, so an offline
    /// launch or a rate-limited reply is retried on the next hourly tick.
    func check(session: URLSession = UpdateChecker.ephemeralSession()) async {
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, _) = try await session.data(from: Self.latestURL)
            let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
            AppSettings.defaults.set(Date(), forKey: AppSettings.lastUpdateCheckKey)
            let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let remote = Self.stripV(latest.tag_name)
            guard Self.isTrustedReleaseURL(latest.html_url) else {
                Log.log("update: ignoring release with an unexpected URL")
                return
            }
            if Self.isNewer(remote, than: local) {
                available = Release(version: remote, url: latest.html_url)
                Log.log("update: \(remote) available (running \(local))")
            } else {
                Log.log("update: up to date (\(local), latest \(remote))")
            }
        } catch {
            Log.log("update: check failed: \(error.localizedDescription)")
        }
    }

    /// The menu item hands this URL to `NSWorkspace.open`, which launches
    /// whatever handles its scheme; only a GitHub https page is opened.
    nonisolated static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
    }

    nonisolated static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric component comparison ("1.10.0" > "1.9.9"; "1.3" == "1.3.0").
    /// Either side malformed (empty, non-numeric component) → false.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parse(_ s: String) -> [Int]? {
            let parts = stripV(s).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            return parts.map { $0! }
        }
        guard let r = parse(remote), let l = parse(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Installed via the Homebrew cask: update with brew, not a manual
    /// download, so brew's record stays in sync.
    static var isHomebrewInstall: Bool {
        Bundle.main.bundlePath == "/Applications/Murmur.app"
            && ["/opt/homebrew/Caskroom/murmur", "/usr/local/Caskroom/murmur"].contains {
                FileManager.default.fileExists(atPath: $0)
            }
    }
}
