import Combine
import Foundation
import LibreLoop
import LoopKitUI

// MARK: - 1-minute glucose exporter (fork feature, DIAforMary/Trio)
//
// Listens to LibreLoop's public `LibreLoopStateObserver` hook, which fires
// for every reading the sensor delivers (independent of LibreLoop's 270 s
// forwarding throttle), and, when enabled in Settings > Nightscout >
// 1-Minute Export (Libre 3), uploads them to Trio's main Nightscout through
// Trio's existing Nightscout connection. Only the readings Trio does not
// upload itself are sent (EXPERIMENTAL: follower apps built for 5-minute
// data, e.g. LoopFollow, will see 1-minute data).
//
// Nothing here writes to Trio's glucose store or talks to the algorithm.
// See MinuteGlucoseExport.swift for the design rules.

final class MinuteGlucoseExporter: ObservableObject {
    static let shared = MinuteGlucoseExporter()

    struct Status: Equatable {
        var isLibreLoopActive = false
        var pendingCount = 0
        var lastUploadAt: Date?
        var lastUploadedReadingAt: Date?
        var lastError: String?
    }

    enum SettingsError: LocalizedError {
        case noPrimaryNightscout

        var errorDescription: String? {
            switch self {
            case .noPrimaryNightscout:
                return String(localized: "No main Nightscout is connected in Trio. Please set it up under Settings > Nightscout first.")
            }
        }
    }

    /// Published on the main thread for the settings screen.
    @Published private(set) var status = Status()

    // Accessed on `workQueue` only.
    private let workQueue = DispatchQueue(label: "MinuteGlucoseExporter.workQueue")
    private var exportQueue = MinuteExportQueue()
    private var uploadInFlight = false
    private var consecutiveFailures = 0
    private var nextAttemptAt = Date.distantPast
    private var isLibreLoopActive = false
    private var lastUploadAt: Date?
    private var lastUploadedReadingAt: Date?
    private var lastError: String?

    // Accessed on the main thread only.
    private weak var observedManager: LibreLoopCGMManager?

    private let keychain: Keychain
    private let defaults: UserDefaults
    private let session: URLSession
    private let queueFileURL: URL?

    private init(keychain: Keychain = BaseKeychain(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = MinuteExportRequest.timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        queueFileURL = Self.makeQueueFileURL()

        workQueue.async { [weak self] in
            self?.loadQueue()
            self?.removeLegacySecondServerSettings()
            self?.publishStatus()
        }
    }

    // MARK: - Settings

    var isEnabled: Bool {
        defaults.bool(forKey: MinuteGlucoseExport.Keys.enabled)
    }

    /// `true` when Trio has a main Nightscout URL configured.
    var hasPrimaryNightscout: Bool {
        primaryNightscoutURL != nil
    }

    private var primaryNightscoutSecret: String {
        let secret: String? = keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
        return secret ?? ""
    }

    private var primaryNightscoutURL: URL? {
        let urlString: String? = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey)
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// Stores the settings. Call from the main thread.
    /// Turning the export off drops readings that are still waiting.
    func saveSettings(enabled: Bool) throws {
        if enabled, primaryNightscoutURL == nil {
            throw SettingsError.noPrimaryNightscout
        }

        defaults.set(enabled, forKey: MinuteGlucoseExport.Keys.enabled)
        debug(.nightscout, "1-min export settings saved, enabled: \(enabled)")

        workQueue.async { [weak self] in
            guard let self else { return }
            self.consecutiveFailures = 0
            self.nextAttemptAt = .distantPast
            self.lastError = nil
            if enabled {
                self.uploadIfNeeded()
            } else {
                self.exportQueue.clearPending()
                self.persistQueue()
            }
            self.publishStatus()
        }
    }

    /// Checks Trio's main Nightscout connection against `/api/v1/verifyauth`.
    /// Calls back on main.
    func testConnection(completion: @escaping (Result<String, Error>) -> Void) {
        guard let server = resolvePrimaryNightscout(),
              let request = MinuteExportRequest.makeVerifyAuthRequest(base: server.base, secret: server.secret)
        else {
            DispatchQueue.main.async { completion(.failure(SettingsError.noPrimaryNightscout)) }
            return
        }

        session.dataTask(with: request) { data, response, error in
            let result: Result<String, Error>
            if let error {
                result = .failure(error)
            } else if let code = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(code) {
                result = .failure(Self.uploadError(statusCode: code))
            } else if let data, let auth = MinuteExportRequest.parseVerifyAuth(data) {
                if auth.authorized, auth.canWrite {
                    result = .success(String(localized: "Connected. The API secret has write access."))
                } else if auth.authorized {
                    result = .failure(Self.message(
                        String(localized: "Connected, but this API secret has no write access. Uploads will be rejected.")
                    ))
                } else {
                    result = .failure(Self.message(
                        String(localized: "Server reached, but the API secret was rejected.")
                    ))
                }
            } else {
                result = .failure(Self.message(
                    String(localized: "Unexpected answer from the main Nightscout.")
                ))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - CGM manager

    /// Called by `PluginSource` whenever its CGM manager is set or replaced.
    /// Observes the manager only if it is LibreLoop (Libre 3 / 3+).
    func attach(to cgmManager: CGMManagerUI?) {
        let libreLoop = cgmManager as? LibreLoopCGMManager
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.observedManager !== libreLoop else { return }
            self.observedManager?.removeStateObserver(self)
            self.observedManager = libreLoop
            libreLoop?.addStateObserver(self)
            debug(.nightscout, "1-min export: LibreLoop \(libreLoop != nil ? "attached" : "not active")")

            let active = libreLoop != nil
            self.workQueue.async {
                self.isLibreLoopActive = active
                self.publishStatus()
            }
        }
    }

    /// Nightscout direction strings, mapped the same way Trio maps the
    /// LibreLoop trend for its own (5-minute) readings.
    static func direction(for trend: LibreLoopGlucoseSample.Trend) -> String {
        switch trend {
        case .risingQuickly: return "SingleUp"
        case .rising: return "FortyFiveUp"
        case .stable: return "Flat"
        case .falling: return "FortyFiveDown"
        case .fallingQuickly: return "SingleDown"
        case .notDetermined: return "NONE"
        }
    }

    /// URL and secret of Trio's own (main) Nightscout connection.
    private func resolvePrimaryNightscout() -> (base: URL, secret: String)? {
        guard let primary = primaryNightscoutURL,
              let base = MinuteExportRequest.normalizedBaseURL(from: primary.absoluteString)
        else { return nil }
        return (base, primaryNightscoutSecret)
    }

    /// Earlier test builds had a "second server" option. Remove its stored
    /// URL, secret and target once, and drop readings queued for it.
    private func removeLegacySecondServerSettings() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let legacyKeys = [MinuteGlucoseExport.LegacyKeys.url, MinuteGlucoseExport.LegacyKeys.target]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        // If the export was set to the second server (the old default), do
        // not silently start uploading to the main Nightscout: switch it off.
        // The user turns it on again deliberately.
        if defaults.string(forKey: MinuteGlucoseExport.LegacyKeys.target) != "primaryNightscout" {
            defaults.set(false, forKey: MinuteGlucoseExport.Keys.enabled)
        }
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        keychain.removeObject(forKey: MinuteGlucoseExport.LegacyKeys.secret)
        exportQueue.clearPending()
        persistQueue()
        debug(.nightscout, "1-min export: removed settings of the former second-server option")
    }

    // MARK: - Queue and upload (workQueue)

    private func handleNewEntry(_ entry: MinuteExportEntry) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard exportQueue.enqueue(entry) else { return }
        persistQueue()
        publishStatus()
        uploadIfNeeded()
    }

    private func uploadIfNeeded() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard isEnabled, !uploadInFlight, Date() >= nextAttemptAt else { return }

        let batch = exportQueue.nextBatch()
        guard !batch.isEmpty else { return }

        guard let server = resolvePrimaryNightscout() else {
            lastError = SettingsError.noPrimaryNightscout.errorDescription
            publishStatus()
            return
        }

        let request: URLRequest
        do {
            request = try MinuteExportRequest.makeUploadRequest(
                base: server.base,
                secret: server.secret,
                entries: batch
            )
        } catch {
            registerFailure(error.localizedDescription)
            return
        }

        uploadInFlight = true
        session.dataTask(with: request) { [weak self] _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            self?.workQueue.async {
                self?.finishUpload(batch: batch, statusCode: statusCode, error: error)
            }
        }.resume()
    }

    private func finishUpload(batch: [MinuteExportEntry], statusCode: Int?, error: Error?) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        uploadInFlight = false

        if error == nil, let statusCode, (200 ..< 300).contains(statusCode) {
            exportQueue.markUploaded(batch)
            consecutiveFailures = 0
            nextAttemptAt = .distantPast
            lastUploadAt = Date()
            if let newest = batch.map(\.date).max() {
                lastUploadedReadingAt = Date(timeIntervalSince1970: TimeInterval(newest) / 1000)
            }
            lastError = nil
            persistQueue()
            publishStatus()
            // Continue with the backlog, if any.
            uploadIfNeeded()
            return
        }

        if let statusCode, [400, 413, 422].contains(statusCode) {
            // The server will never accept this batch; drop it instead of
            // blocking the queue forever.
            exportQueue.markUploaded(batch)
            persistQueue()
            debug(.nightscout, "1-min export: server rejected \(batch.count) readings with HTTP \(statusCode), dropped")
        }

        let description = error?.localizedDescription
            ?? Self.uploadError(statusCode: statusCode ?? -1).localizedDescription
        registerFailure(description)
    }

    private func registerFailure(_ description: String) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        consecutiveFailures += 1
        nextAttemptAt = Date().addingTimeInterval(MinuteExportRequest.backoff(afterFailures: consecutiveFailures))
        lastError = description
        debug(.nightscout, "1-min export upload failed (\(consecutiveFailures)x): \(description)")
        publishStatus()
    }

    private func publishStatus() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let snapshot = Status(
            isLibreLoopActive: isLibreLoopActive,
            pendingCount: exportQueue.pending.count,
            lastUploadAt: lastUploadAt,
            lastUploadedReadingAt: lastUploadedReadingAt,
            lastError: lastError
        )
        DispatchQueue.main.async { [weak self] in
            if self?.status != snapshot {
                self?.status = snapshot
            }
        }
    }

    // MARK: - Persistence (workQueue)

    private static func makeQueueFileURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return directory
            .appendingPathComponent("MinuteGlucoseExport", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    private func loadQueue() {
        guard let queueFileURL, let data = try? Data(contentsOf: queueFileURL) else { return }
        if let stored = try? JSONDecoder().decode(MinuteExportQueue.self, from: data) {
            exportQueue = stored
        }
    }

    private func persistQueue() {
        guard let queueFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: queueFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(exportQueue)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            debug(.nightscout, "1-min export: could not save queue: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    private struct MessageError: LocalizedError {
        let errorDescription: String?
    }

    private static func message(_ text: String) -> Error {
        MessageError(errorDescription: text)
    }

    private static func uploadError(statusCode: Int) -> Error {
        switch statusCode {
        case 401,
             403:
            return message(String(localized: "Not authorized (HTTP \(statusCode)). Please check the API secret."))
        case 404:
            return message(String(localized: "Not found (HTTP 404). Please check the URL."))
        default:
            return message(String(localized: "Server error (HTTP \(statusCode))."))
        }
    }
}

// MARK: - LibreLoop observer

extension MinuteGlucoseExporter: LibreLoopStateObserver {
    /// LibreLoop calls this on the main thread after every state change,
    /// including each new minute reading.
    func libreLoopCGMManager(
        _: LibreLoopCGMManager,
        didUpdate state: LibreLoopCGMManagerState,
        latestSample: LibreLoopGlucoseSample?
    ) {
        guard let sample = latestSample else { return }
        // Only live readings; skip readings the sensor itself flagged as
        // faulty (LibreLoop does not forward those to Trio either).
        guard sample.source == .realtime, !sample.hasBlockingIssue else { return }

        let identifier = MinuteExportEntry.makeIdentifier(sensorSerial: state.sensorSerial, lifeCount: sample.lifeCount)

        // Keep every minute reading for the chart and the glucose bubble, in
        // a separate store (never in Trio's glucose table). No-op unless one
        // of the display options is on.
        MinuteGlucoseStore.shared.record(
            MinuteGlucoseReading(id: identifier, date: sample.date, mgdl: Int(sample.valueMgDL))
        )

        guard isEnabled else { return }

        // Trio uploads the readings LibreLoop forwards to it (about every
        // 5 minutes) itself; send only the ones LibreLoop held back, so
        // Trio's own entries stay untouched and nothing is duplicated.
        // Until LibreLoop has decided (wasForwarded false and no skip
        // reason yet), wait: it notifies again once the outcome is set.
        if sample.wasForwarded || sample.forwardSkipReason == nil { return }

        let entry = MinuteExportEntry(
            identifier: identifier,
            // Truncated like Trio's own glucose values.
            mgdl: Int(sample.valueMgDL),
            date: sample.date,
            direction: Self.direction(for: sample.trend)
        )
        workQueue.async { [weak self] in
            self?.handleNewEntry(entry)
        }
    }
}
