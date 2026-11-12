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
// Two display-only uses, each with its own switch (both off by default):
// - the main chart shows them as small extra dots behind the 5-minute dots
// - the glucose bubble can show the newest minute reading, either as a small
//   line below the 5-minute value or as the main value (see MinuteBubbleMode)

/// One minute reading for the chart.
struct MinuteGlucoseReading: Codable, Equatable, Identifiable {
    /// `libreloop-<sensorSerial>-<lifeCount>`, same as the export identifier.
    let id: String
    let date: Date
    let mgdl: Int
}

/// How the glucose bubble on the home screen uses minute readings.
enum MinuteBubbleMode: String, CaseIterable, Identifiable {
    /// Unchanged Trio: only the 5-minute value.
    case off
    /// "Minute value with 5-min footnote": big number = newest minute reading;
    /// below it "#1 … #5" (position in the 5-minute cycle, #5 = the 5-minute
    /// reading) with the change from the previous minute reading, and a
    /// smaller line with the last 5-minute value and the total change since it.
    /// Raw value kept from the former "Small line" mode, so a stored choice
    /// carries over.
    case minuteWithFootnote = "smallLine"
    /// Big number shows the newest minute reading; the delta is the change
    /// over the last 5 minutes (not over 1 minute); a small "1-min" label
    /// marks it.
    case mainValue

    var id: String { rawValue }
}

/// What the bubble shows for minute readings. Pure value, unit-tested.
struct MinuteBubbleInfo: Equatable {
    /// Newest minute reading.
    let mgdl: Int
    let date: Date
    /// Whole minutes between Trio's last 5-minute reading and this reading
    /// (1 ... 4 normally). `nil` if there is no 5-minute reading to compare.
    let minutesAfterFiveMinuteReading: Int?
    /// Newest minute value minus the minute value about 5 minutes earlier
    /// (mg/dL). `nil` if no reading 5 minutes earlier (± 90 s) exists.
    let fiveMinuteDelta: Int?
    /// Newest minute value minus the reading before it (mg/dL), if that one is
    /// 30 s … 3 min older; otherwise `nil`.
    let oneMinuteDelta: Int?

    /// A minute reading older than this is ignored (the bubble then falls
    /// back to plain 5-minute display).
    static let maxAge: TimeInterval = 3 * 60

    /// - Parameters:
    ///   - readings: minute readings, oldest first.
    ///   - lastFiveMinuteDate: date of Trio's newest 5-minute reading.
    /// - Returns: `nil` when there is no fresh minute reading.
    static func make(
        readings: [MinuteGlucoseReading],
        lastFiveMinuteDate: Date?,
        now: Date = Date()
    ) -> MinuteBubbleInfo? {
        guard let latest = readings.last,
              now.timeIntervalSince(latest.date) < maxAge,
              latest.date <= now.addingTimeInterval(60)
        else { return nil }

        var minutesAfter: Int?
        if let lastFiveMinuteDate {
            minutesAfter = Int((latest.date.timeIntervalSince(lastFiveMinuteDate) / 60).rounded())
        }

        let targetDate = latest.date.addingTimeInterval(-5 * 60)
        let reference = readings
            .filter { abs($0.date.timeIntervalSince(targetDate)) <= 90 }
            .min { abs($0.date.timeIntervalSince(targetDate)) < abs($1.date.timeIntervalSince(targetDate)) }

        var oneMinuteDelta: Int?
        if readings.count >= 2 {
            let previous = readings[readings.count - 2]
            let gap = latest.date.timeIntervalSince(previous.date)
            if gap >= 30, gap <= 180 {
                oneMinuteDelta = latest.mgdl - previous.mgdl
            }
        }

        return MinuteBubbleInfo(
            mgdl: latest.mgdl,
            date: latest.date,
            minutesAfterFiveMinuteReading: minutesAfter,
            fiveMinuteDelta: reference.map { latest.mgdl - $0.mgdl },
            oneMinuteDelta: oneMinuteDelta
        )
    }
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
    /// UserDefaults: String, raw value of `MinuteBubbleMode`. Off by default.
    static let bubbleModeKey = "MinuteGlucoseExport.bubbleMode"

    /// Readings for the chart, published on the main thread. Empty while
    /// "Show minute readings in chart" is off.
    @Published private(set) var chartReadings: [MinuteGlucoseReading] = []
    /// Readings of the last 15 minutes for the glucose bubble, published on
    /// the main thread. Empty while the bubble mode is off.
    @Published private(set) var recentReadings: [MinuteGlucoseReading] = []
    /// Current bubble mode, published on the main thread.
    @Published private(set) var bubbleMode: MinuteBubbleMode = .off

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
        bubbleMode = defaults.string(forKey: Self.bubbleModeKey).flatMap(MinuteBubbleMode.init(rawValue:)) ?? .off

        workQueue.async { [weak self] in
            self?.load()
            self?.publish()
        }
    }

    var isShownInChart: Bool {
        defaults.bool(forKey: Self.showInChartKey)
    }

    private var storedBubbleMode: MinuteBubbleMode {
        defaults.string(forKey: Self.bubbleModeKey).flatMap(MinuteBubbleMode.init(rawValue:)) ?? .off
    }

    /// `true` while any display feature needs minute readings.
    private var isRecording: Bool {
        isShownInChart || storedBubbleMode != .off
    }

    /// Turns the chart dots on or off. Call from the main thread.
    /// When neither chart dots nor bubble use minute readings any more, the
    /// stored minute readings are deleted.
    func setShownInChart(_ shown: Bool) {
        defaults.set(shown, forKey: Self.showInChartKey)
        settingsChanged()
    }

    /// Sets the glucose bubble mode. Call from the main thread.
    func setBubbleMode(_ mode: MinuteBubbleMode) {
        defaults.set(mode.rawValue, forKey: Self.bubbleModeKey)
        bubbleMode = mode
        settingsChanged()
    }

    private func settingsChanged() {
        let recording = isRecording
        workQueue.async { [weak self] in
            guard let self else { return }
            if !recording {
                self.buffer.removeAll()
                self.persist()
            }
            self.publish()
        }
    }

    /// Records a minute reading (only while a display feature is on).
    func record(_ reading: MinuteGlucoseReading) {
        guard isRecording else { return }
        workQueue.async { [weak self] in
            guard let self, self.buffer.add(reading) else { return }
            self.persist()
            self.publish()
        }
    }

    // MARK: - Private (workQueue)

    private func publish() {
        let chart = isShownInChart ? buffer.readings : []
        let cutoff = Date().addingTimeInterval(-15 * 60)
        let recent = storedBubbleMode != .off ? buffer.readings.filter { $0.date >= cutoff } : []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.chartReadings != chart {
                self.chartReadings = chart
            }
            if self.recentReadings != recent {
                self.recentReadings = recent
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
