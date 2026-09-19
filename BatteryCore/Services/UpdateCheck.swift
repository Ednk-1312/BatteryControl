import Foundation

/// Passive update check against the project's GitHub releases. There is no
/// auto-download and no auto-install — an in-place upgrade is exactly the
/// disruption the 1.0.2 stale-process work exists to survive, so updating
/// stays a deliberate user action. The request carries no identifiers
/// beyond what any HTTPS fetch exposes.
///
/// The decision logic is pure and unit-tested; the network fetch lives in
/// the GUI (and the opt-in `batterycontrol update-check` CLI command).
public enum UpdateCheck {

    /// Where releases live.
    public static let releasesURL = URL(string: "https://github.com/Ednk-1312/BatteryControl/releases")!
    /// The single API endpoint queried; `releases/latest` returns the newest
    /// non-draft, non-prerelease release.
    public static let apiLatestRelease = URL(string: "https://api.github.com/repos/Ednk-1312/BatteryControl/releases/latest")!

    /// How often a check is performed. Failed checks are retried on the
    /// same cadence; nothing retries aggressively.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// One release as BatteryControl cares about it.
    public struct Release: Codable, Equatable, Sendable {
        /// e.g. "1.1.0".
        public var tagName: String
        /// Human-facing page for the release.
        public var htmlURL: String

        public init(tagName: String, htmlURL: String) {
            self.tagName = tagName
            self.htmlURL = htmlURL
        }
    }

    /// Errors from parsing an API response.
    public enum ParseError: Error, Equatable {
        case malformed
        case notARelease
    }

    /// Parse the GitHub `releases/latest` JSON. Draft and prerelease
    /// entries are refused (`notARelease`) — the app must never point
    /// users at unrelease-quality artifacts.
    public static func parseLatestRelease(fromData data: Data) throws -> Release {
        struct APIRelease: Decodable {
            var tag_name: String?
            var html_url: String?
            var draft: Bool?
            var prerelease: Bool?
        }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        guard let tag = api.tag_name, !tag.isEmpty,
              let url = api.html_url, !url.isEmpty,
              api.draft != true, api.prerelease != true
        else { throw ParseError.notARelease }
        return Release(tagName: tag, htmlURL: url)
    }

    /// True when `candidate` is a strictly newer semantic version than
    /// `current`. Non-numeric or malformed versions return false — an
    /// unparseable version never triggers a "newer available" claim.
    /// Pre-release suffixes ("1.2.0-beta1") are compared by their numeric
    /// core only; equality of the numeric core is not "newer".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateCore = numericCore(candidate),
              let currentCore = numericCore(current) else { return false }
        return compare(candidateCore, currentCore) > 0
    }

    /// Whether a check is due given the last completed check.
    /// Nil lastCheck (never checked) is always due.
    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    // MARK: - Version comparison internals

    /// "v1.2.3", "1.2.3-beta1" → [1, 2, 3]; nil when there is no numeric
    /// leading version at all.
    private static func numericCore(_ version: String) -> [Int]? {
        var cleaned = version.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned = String(cleaned.dropFirst())
        }
        // Strip any pre-release/build suffix.
        if let dash = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dash])
        }
        if let plus = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plus])
        }
        let parts = cleaned.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    /// Numeric tuple comparison, treating missing components as 0
    /// ("1.2" == "1.2.0").
    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
