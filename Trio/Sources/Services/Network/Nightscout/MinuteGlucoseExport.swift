import CryptoKit
import Foundation

// MARK: - 1-minute glucose export (fork feature, DIAforMary/Trio)
//
// Optional, opt-in export of the Libre 3 minute readings that LibreLoop
// receives, either to a second Nightscout-compatible server (e.g. Nocturne)
// or, experimentally, to Trio's main Nightscout (see MinuteExportTarget).
//
// Design rule: this feature is purely additive. It never writes to
// `GlucoseStored`, never triggers a loop, never touches the algorithm,
// alarms, delta displays or Trio's own Nightscout upload. If it fails,
// the only effect is that the minute readings do not reach the server.
//
// This file holds the Foundation-only parts (data model, queue, request
// building, URL checks) so they can be unit-tested without a CGM.

enum MinuteGlucoseExport {
    /// `device` field on every uploaded entry, so the 1-minute stream is
    /// easy to tell apart on the receiving server.
    static let deviceName = "Trio-LibreLoop-1min"

    /// Keep at most 24 h of minute readings while the server is unreachable.
    static let maxQueuedEntries = 1440

    /// Upper bound per POST request.
    static let uploadBatchLimit = 100

    /// How many recently enqueued identifiers are remembered to suppress
    /// duplicates (LibreLoop notifies observers on every state change, not
    /// only on new readings).
    static let recentIdentifierMemory = 300

    enum Keys {
        /// UserDefaults: Bool, feature switch. Off by default.
        static let enabled = "MinuteGlucoseExport.enabled"
        /// UserDefaults: String, base URL of the secondary server.
        static let url = "MinuteGlucoseExport.url"
        /// Keychain: String, API secret of the secondary server.
        static let secret = "MinuteGlucoseExport.secret"
        /// UserDefaults: String, raw value of `MinuteExportTarget`.
        static let target = "MinuteGlucoseExport.target"
    }
}

/// Where the minute readings go.
enum MinuteExportTarget: String, CaseIterable, Identifiable {
    /// A separate Nightscout-compatible server (e.g. Nocturne). All minute
    /// readings are sent there. Recommended.
    case secondServer
    /// EXPERIMENTAL: Trio's own (primary) Nightscout. Only the minute
    /// readings Trio does NOT upload itself are sent, in exactly Trio's
    /// format, so the 5-minute readings stay untouched. Follower apps that
    /// assume 5-minute data (e.g. LoopFollow deltas and fast-drop alarms)
    /// will see 1-minute data.
    case primaryNightscout

    var id: String { rawValue }
}

// MARK: - Entry

/// One Nightscout `entries` document of type `sgv`.
struct MinuteExportEntry: Codable, Equatable {
    /// Stable per reading: `libreloop-<sensorSerial>-<lifeCount>`.
    let identifier: String
    let type: String
    let sgv: Int
    /// Milliseconds since 1970.
    let date: Int64
    /// ISO 8601 with milliseconds, UTC.
    let dateString: String
    /// Nightscout direction string, e.g. "Flat", "FortyFiveUp".
    let direction: String
    let device: String

    init(identifier: String, mgdl: Int, date: Date, direction: String, device: String = MinuteGlucoseExport.deviceName) {
        self.identifier = identifier
        type = "sgv"
        sgv = mgdl
        // Truncated like Trio's own uploads (`Int(date * 1000)`), so the same
        // reading always gets the same millisecond timestamp.
        self.date = Int64(date.timeIntervalSince1970 * 1000)
        dateString = MinuteExportEntry.isoFormatter.string(from: date)
        self.direction = direction
        self.device = device
    }

    static func makeIdentifier(sensorSerial: String?, lifeCount: UInt16) -> String {
        "libreloop-\(sensorSerial ?? "unknown")-\(lifeCount)"
    }

    /// The JSON document sent to the server. For the primary Nightscout,
    /// `device` and `identifier` are left out so the document looks exactly
    /// like the ones Trio uploads itself.
    func uploadDocument(for target: MinuteExportTarget) -> MinuteExportUploadDocument {
        MinuteExportUploadDocument(
            type: type,
            sgv: sgv,
            date: date,
            dateString: dateString,
            direction: direction,
            device: target == .secondServer ? device : nil,
            identifier: target == .secondServer ? identifier : nil
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// Wire format of one uploaded entry; `nil` fields are omitted.
struct MinuteExportUploadDocument: Encodable, Equatable {
    let type: String
    let sgv: Int
    let date: Int64
    let dateString: String
    let direction: String
    let device: String?
    let identifier: String?
}

// MARK: - Queue

/// Pending uploads plus a bounded memory of what was already enqueued.
/// Value type; the exporter owns one instance and persists it as JSON.
struct MinuteExportQueue: Codable, Equatable {
    private(set) var pending: [MinuteExportEntry] = []
    private(set) var recentIdentifiers: [String] = []

    init() {}

    /// Adds an entry unless it was enqueued recently. Keeps `pending` sorted
    /// oldest first and capped at `maxQueuedEntries` (oldest dropped).
    /// - Returns: `true` if the entry was added.
    @discardableResult mutating func enqueue(
        _ entry: MinuteExportEntry,
        maxEntries: Int = MinuteGlucoseExport.maxQueuedEntries,
        identifierMemory: Int = MinuteGlucoseExport.recentIdentifierMemory
    ) -> Bool {
        guard !recentIdentifiers.contains(entry.identifier) else { return false }

        recentIdentifiers.append(entry.identifier)
        if recentIdentifiers.count > identifierMemory {
            recentIdentifiers.removeFirst(recentIdentifiers.count - identifierMemory)
        }

        if let last = pending.last, last.date > entry.date {
            let index = pending.firstIndex { $0.date > entry.date } ?? pending.endIndex
            pending.insert(entry, at: index)
        } else {
            pending.append(entry)
        }

        if pending.count > maxEntries {
            pending.removeFirst(pending.count - maxEntries)
        }
        return true
    }

    /// Oldest pending entries, at most `limit`.
    func nextBatch(limit: Int = MinuteGlucoseExport.uploadBatchLimit) -> [MinuteExportEntry] {
        Array(pending.prefix(max(0, limit)))
    }

    /// Removes successfully uploaded entries.
    mutating func markUploaded(_ entries: [MinuteExportEntry]) {
        let uploaded = Set(entries.map(\.identifier))
        pending.removeAll { uploaded.contains($0.identifier) }
    }

    /// Drops all pending entries (identifier memory is kept, so readings
    /// that were already seen are not enqueued again).
    mutating func clearPending() {
        pending.removeAll()
    }
}

// MARK: - Requests and URL checks

enum MinuteExportRequest {
    static let timeout: TimeInterval = 30

    /// Parses the user's input into a base URL. Requires https and a host.
    /// Keeps a path prefix (sub-path installs) and query items (e.g. `token=`).
    static func normalizedBaseURL(from input: String) -> URL? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = "https"
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.fragment = nil
        return components.url
    }

    /// `true` if both URLs point to the same server (host, case-insensitive,
    /// and effective port). Used to refuse the primary Nightscout.
    static func isSameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased() else { return false }
        return lhsHost == rhsHost && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }

    /// `<base>/api/v1/<endpoint>`, keeping base path prefix and query items.
    static func endpointURL(base: URL, endpoint: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/api/v1/" + endpoint
        return components.url
    }

    static func makeUploadRequest(
        base: URL,
        secret: String?,
        entries: [MinuteExportEntry],
        target: MinuteExportTarget
    ) throws -> URLRequest {
        guard let url = endpointURL(base: base, endpoint: "entries.json") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            request.addValue(sha1Hex(secret), forHTTPHeaderField: "api-secret")
        }
        request.httpBody = try JSONEncoder().encode(entries.map { $0.uploadDocument(for: target) })
        return request
    }

    static func makeVerifyAuthRequest(base: URL, secret: String?) -> URLRequest? {
        guard let url = endpointURL(base: base, endpoint: "verifyauth") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            request.addValue(sha1Hex(secret), forHTTPHeaderField: "api-secret")
        }
        return request
    }

    /// Result of `/api/v1/verifyauth`. Nightscout and Nocturne both answer
    /// 200 and put "OK" or "UNAUTHORIZED" plus `canWrite` in `message`.
    struct VerifyAuthResult: Equatable {
        let authorized: Bool
        let canWrite: Bool
    }

    static func parseVerifyAuth(_ data: Data) -> VerifyAuthResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Envelope `{status, message: {...}}`; tolerate a flat object too.
        let body = (object["message"] as? [String: Any]) ?? object
        guard let message = body["message"] as? String else { return nil }
        let canWrite = (body["canWrite"] as? Bool) ?? false
        return VerifyAuthResult(authorized: message.uppercased() == "OK", canWrite: canWrite)
    }

    static func sha1Hex(_ string: String) -> String {
        Insecure.SHA1.hash(data: Data(string.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    /// Delay before the next attempt after `failures` consecutive failures:
    /// 1, 2, 4, 8 min, capped at 15 min.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let minutes = min(15.0, pow(2.0, Double(min(failures, 5) - 1)))
        return minutes * 60
    }
}
