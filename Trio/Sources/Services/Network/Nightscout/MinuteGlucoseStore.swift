import Combine
import Foundation

// MARK: - 1-minute display store (fork feature, DIAforMary/Trio, branch libre-1min-display)
//
// Keeps the Libre 3 minute readings in their OWN small file, completely
// separate from Trio's Core Data glucose table (`GlucoseStored`):
//
// - The algorithm, alarms, deltas, statistics, Watch, Live Activity,
//   HealthKit and Tidepool keep reading `GlucoseStored` (5-minute data) and
//   never see these readings.
// - Trio's database model is not changed, so a build of this branch can be
//   replaced by the lighter `libre-1min-export` build or by original Trio at
//   any time; the extra file is simply ignored there.
//
// The main chart shows these readings as small extra dots behind the normal
// 5-minute dots when "Show minute readings in chart" is on.

/// One minute reading for the chart.
struct MinuteGlucoseReading: Codable, Equatable, Identifiable {
    /// `libreloop-<sensorSerial>-<lifeCount>`, same as the export identifier.
    let id: String
    let date: Date
    let mgdl: Int
}

/// Value type holding the readings; unit-tested without a sensor.
struct MinuteReadingBuffer: Codable, Equatable {
    static let defaultRetention: TimeInterval = 24 * 60 * 60
    static let defaultMaxCount = 1600

    private(set) var readings: [MinuteGlucoseReading] = []

    init() {}

    /// Adds a reading unless one with the same id exists. Keeps readings
    /// sorted oldest first, drops readings older than `retention` (relative
    /// to `now`) and caps the count.
    /// - Returns: `true` if the reading was added.
    @discardableResult mutating func add(
        _ reading: MinuteGlucoseReading,
        now: Date = Date(),
        retention: TimeInterval = MinuteReadingBuffer.defaultRetention,
        maxCount: Int = MinuteReadingBuffer.defaultMaxCount
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-retention)
        guard reading.date >= cutoff else { return false }
        guard !readings.contains(where: { $0.id == reading.id }) else { return false }

        if let last = readings.last, last.date > reading.date {
            let index = readings.firstIndex { $0.date > reading.date } ?? readings.endIndex
            readings.insert(reading, at: index)
        } else {
            readings.append(reading)
        }

        readings.removeAll { $0.date < cutoff }
        if readings.count > maxCount {
            readings.removeFirst(readings.count - maxCount)
        }
        return true
    }

    mutating func removeAll() {
        readings.removeAll()
    }
}

final class MinuteGlucoseStore: ObservableObject {
    static let shared = MinuteGlucoseStore()

    /// UserDefaults: Bool, show minute readings in the main chart. Off by default.
    static let showInChartKey = "MinuteGlucoseExport.showInChart"

    /// Readings for the chart, published on the main thread. Empty while
    /// "Show minute readings in chart" is off.
    @Published private(set) var chartReadings: [MinuteGlucoseReading] = []

    // Accessed on `workQueue` only.
    private let workQueue = DispatchQueue(label: "MinuteGlucoseStore.workQueue")
    private var buffer = MinuteReadingBuffer()

    private let defaults: UserDefaults
    private let fileURL: URL?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MinuteGlucoseExport", isDirectory: true)
            .appendingPathComponent("chart-readings.json")

        workQueue.async { [weak self] in
            self?.load()
            self?.publish()
        }
    }

    var isShownInChart: Bool {
        defaults.bool(forKey: Self.showInChartKey)
    }

    /// Turns the chart dots on or off. Turning them off also deletes the
    /// stored minute readings. Call from the main thread.
    func setShownInChart(_ shown: Bool) {
        defaults.set(shown, forKey: Self.showInChartKey)
        workQueue.async { [weak self] in
            guard let self else { return }
            if !shown {
                self.buffer.removeAll()
                self.persist()
            }
            self.publish()
        }
    }

    /// Records a minute reading (only while the chart dots are on).
    func record(_ reading: MinuteGlucoseReading) {
        guard isShownInChart else { return }
        workQueue.async { [weak self] in
            guard let self, self.buffer.add(reading) else { return }
            self.persist()
            self.publish()
        }
    }

    // MARK: - Private (workQueue)

    private func publish() {
        let readings = isShownInChart ? buffer.readings : []
        DispatchQueue.main.async { [weak self] in
            if self?.chartReadings != readings {
                self?.chartReadings = readings
            }
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(MinuteReadingBuffer.self, from: data)
        else { return }
        buffer = stored
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(buffer).write(to: fileURL, options: .atomic)
        } catch {
            debug(.nightscout, "1-min display: could not save readings: \(error.localizedDescription)")
        }
    }
}
