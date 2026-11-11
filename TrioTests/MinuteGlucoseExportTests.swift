import Foundation
import Testing

@testable import Trio

/// Fork feature (DIAforMary/Trio): 1-minute export to a second
/// Nightscout-compatible server. Covers the Foundation-only parts.
@Suite("MinuteGlucoseExport: queue, requests and URL checks") struct MinuteGlucoseExportTests {
    private func entry(_ lifeCount: UInt16, secondsFromStart: TimeInterval = 0, mgdl: Int = 100) -> MinuteExportEntry {
        MinuteExportEntry(
            identifier: MinuteExportEntry.makeIdentifier(sensorSerial: "SN1", lifeCount: lifeCount),
            mgdl: mgdl,
            date: Date(timeIntervalSince1970: 1_800_000_000 + secondsFromStart),
            direction: "Flat"
        )
    }

    // MARK: - URL handling

    @Test("Base URL: adds https, strips trailing slash, keeps token query") func normalizedBaseURL() {
        #expect(MinuteExportRequest.normalizedBaseURL(from: " https://nsa.example.org/ ")?.absoluteString == "https://nsa.example.org")
        #expect(MinuteExportRequest.normalizedBaseURL(from: "nsa.example.org")?.absoluteString == "https://nsa.example.org")
        #expect(
            MinuteExportRequest.normalizedBaseURL(from: "https://example.org/ns/?token=abc")?.absoluteString ==
                "https://example.org/ns?token=abc"
        )
        #expect(MinuteExportRequest.normalizedBaseURL(from: "http://insecure.example.org") == nil)
        #expect(MinuteExportRequest.normalizedBaseURL(from: "") == nil)
        #expect(MinuteExportRequest.normalizedBaseURL(from: "https://") == nil)
    }

    @Test("Same-server check compares host case-insensitively and port") func sameServer() {
        let primary = URL(string: "https://My-NS.example.org")!
        #expect(MinuteExportRequest.isSameServer(URL(string: "https://my-ns.example.org/sub")!, primary))
        #expect(MinuteExportRequest.isSameServer(URL(string: "https://my-ns.example.org:443")!, primary))
        #expect(!MinuteExportRequest.isSameServer(URL(string: "https://my-ns.example.org:8443")!, primary))
        #expect(!MinuteExportRequest.isSameServer(URL(string: "https://nocturne.example.org")!, primary))
    }

    @Test("Endpoint URL keeps path prefix and query items") func endpointURL() {
        let base = URL(string: "https://example.org/ns?token=abc")!
        #expect(
            MinuteExportRequest.endpointURL(base: base, endpoint: "entries.json")?.absoluteString ==
                "https://example.org/ns/api/v1/entries.json?token=abc"
        )
    }

    // MARK: - Queue

    @Test("Queue ignores duplicates and keeps oldest first") func queueDedupAndOrder() {
        var queue = MinuteExportQueue()
        let added10 = queue.enqueue(entry(10, secondsFromStart: 600))
        let added8 = queue.enqueue(entry(8, secondsFromStart: 480))
        let added9 = queue.enqueue(entry(9, secondsFromStart: 540))
        let addedDuplicate = queue.enqueue(entry(9, secondsFromStart: 540))
        #expect(added10 && added8 && added9)
        #expect(!addedDuplicate)
        #expect(queue.pending.map(\.identifier) == ["libreloop-SN1-8", "libreloop-SN1-9", "libreloop-SN1-10"])
    }

    @Test("Queue drops the oldest entries above the cap") func queueCap() {
        var queue = MinuteExportQueue()
        for lifeCount in UInt16(1) ... 5 {
            queue.enqueue(entry(lifeCount, secondsFromStart: TimeInterval(lifeCount) * 60), maxEntries: 3)
        }
        #expect(queue.pending.map(\.identifier) == ["libreloop-SN1-3", "libreloop-SN1-4", "libreloop-SN1-5"])
    }

    @Test("Uploaded entries leave the queue; cleared readings are not re-added") func queueUploadAndClear() {
        var queue = MinuteExportQueue()
        for lifeCount in UInt16(1) ... 4 {
            queue.enqueue(entry(lifeCount, secondsFromStart: TimeInterval(lifeCount) * 60))
        }
        let batch = queue.nextBatch(limit: 2)
        #expect(batch.map(\.identifier) == ["libreloop-SN1-1", "libreloop-SN1-2"])
        queue.markUploaded(batch)
        #expect(queue.pending.count == 2)

        queue.clearPending()
        #expect(queue.pending.isEmpty)
        let readdedCleared = queue.enqueue(entry(4, secondsFromStart: 240))
        let addedNew = queue.enqueue(entry(5, secondsFromStart: 300))
        #expect(!readdedCleared)
        #expect(addedNew)
    }

    @Test("Queue survives a JSON round trip") func queuePersistence() throws {
        var queue = MinuteExportQueue()
        queue.enqueue(entry(1))
        let restored = try JSONDecoder().decode(MinuteExportQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored == queue)
    }

    // MARK: - Entries and requests

    @Test("Entry encodes the Nightscout sgv fields") func entryEncoding() throws {
        let data = try JSONEncoder().encode(entry(42, mgdl: 123))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "sgv")
        #expect(object["sgv"] as? Int == 123)
        #expect((object["date"] as? NSNumber)?.int64Value == 1_800_000_000_000)
        #expect(object["dateString"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(object["direction"] as? String == "Flat")
        #expect(object["device"] as? String == MinuteGlucoseExport.deviceName)
        #expect(object["identifier"] as? String == "libreloop-SN1-42")
    }

    @Test("Upload request: POST entries.json with hashed api-secret") func uploadRequest() throws {
        let base = URL(string: "https://nocturne.example.org")!
        let request = try MinuteExportRequest.makeUploadRequest(
            base: base,
            secret: "test",
            entries: [entry(1)],
            target: .secondServer
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://nocturne.example.org/api/v1/entries.json")
        #expect(request.value(forHTTPHeaderField: "api-secret") == "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")
        let body = try JSONDecoder().decode([MinuteExportEntry].self, from: try #require(request.httpBody))
        #expect(body == [entry(1)])
    }

    @Test("Main Nightscout target sends Trio's format: no device, no identifier") func primaryTargetDocument() throws {
        let base = URL(string: "https://my-ns.example.org")!
        let request = try MinuteExportRequest.makeUploadRequest(
            base: base,
            secret: "test",
            entries: [entry(7, mgdl: 140)],
            target: .primaryNightscout
        )
        let body = try #require(request.httpBody)
        let array = try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let object = try #require(array.first)
        #expect(object["device"] == nil)
        #expect(object["identifier"] == nil)
        #expect(object["type"] as? String == "sgv")
        #expect(object["sgv"] as? Int == 140)
        #expect(object["dateString"] as? String == "2027-01-15T08:00:00.000Z")
    }

    @Test("Timestamps are truncated to the millisecond, like Trio's uploads") func dateTruncation() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.9999)
        let entry = MinuteExportEntry(identifier: "x", mgdl: 100, date: date, direction: "Flat")
        #expect(entry.date == 1_800_000_000_999)
    }

    @Test("Upload request without secret sends no api-secret header") func uploadRequestWithoutSecret() throws {
        let base = URL(string: "https://example.org?token=abc")!
        let request = try MinuteExportRequest.makeUploadRequest(
            base: base,
            secret: "  ",
            entries: [entry(1)],
            target: .secondServer
        )
        #expect(request.value(forHTTPHeaderField: "api-secret") == nil)
    }

    @Test("verifyauth answers from Nightscout and Nocturne are understood") func verifyAuthParsing() {
        let ok = Data(#"{"status":200,"message":{"canRead":true,"canWrite":true,"isAdmin":true,"message":"OK"}}"#.utf8)
        #expect(MinuteExportRequest.parseVerifyAuth(ok) == .init(authorized: true, canWrite: true))

        let denied = Data(#"{"status":200,"message":{"canRead":false,"canWrite":false,"message":"UNAUTHORIZED"}}"#.utf8)
        #expect(MinuteExportRequest.parseVerifyAuth(denied) == .init(authorized: false, canWrite: false))

        #expect(MinuteExportRequest.parseVerifyAuth(Data("<html></html>".utf8)) == nil)
    }

    @Test("Backoff grows 1, 2, 4, 8 min and caps at 15 min") func backoff() {
        #expect(MinuteExportRequest.backoff(afterFailures: 0) == 0)
        #expect(MinuteExportRequest.backoff(afterFailures: 1) == 60)
        #expect(MinuteExportRequest.backoff(afterFailures: 2) == 120)
        #expect(MinuteExportRequest.backoff(afterFailures: 4) == 480)
        #expect(MinuteExportRequest.backoff(afterFailures: 5) == 900)
        #expect(MinuteExportRequest.backoff(afterFailures: 50) == 900)
    }
}

/// Fork feature (branch libre-1min-display): separate store for chart dots.
@Suite("MinuteGlucoseStore: separate minute-reading buffer") struct MinuteReadingBufferTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ id: Int, minutesAgo: Double, mgdl: Int = 100) -> MinuteGlucoseReading {
        MinuteGlucoseReading(id: "r\(id)", date: now.addingTimeInterval(-minutesAgo * 60), mgdl: mgdl)
    }

    @Test("Buffer ignores duplicates and keeps oldest first") func dedupAndOrder() {
        var buffer = MinuteReadingBuffer()
        let addedA = buffer.add(reading(1, minutesAgo: 1), now: now)
        let addedB = buffer.add(reading(3, minutesAgo: 3), now: now)
        let addedC = buffer.add(reading(2, minutesAgo: 2), now: now)
        let addedDuplicate = buffer.add(reading(2, minutesAgo: 2), now: now)
        #expect(addedA && addedB && addedC)
        #expect(!addedDuplicate)
        #expect(buffer.readings.map(\.id) == ["r3", "r2", "r1"])
    }

    @Test("Buffer drops readings older than the retention window") func retention() {
        var buffer = MinuteReadingBuffer()
        buffer.add(reading(1, minutesAgo: 30), now: now, retention: 3600)
        let addedTooOld = buffer.add(reading(2, minutesAgo: 90), now: now, retention: 3600)
        #expect(!addedTooOld)
        // A later "now" pushes the first reading out of the window.
        buffer.add(reading(3, minutesAgo: 0), now: now.addingTimeInterval(45 * 60), retention: 3600)
        #expect(buffer.readings.map(\.id) == ["r3"])
    }

    @Test("Buffer caps the number of readings") func cap() {
        var buffer = MinuteReadingBuffer()
        for index in 1 ... 5 {
            buffer.add(reading(index, minutesAgo: Double(10 - index)), now: now, maxCount: 3)
        }
        #expect(buffer.readings.map(\.id) == ["r3", "r4", "r5"])
    }

    @Test("Buffer survives a JSON round trip") func persistence() throws {
        var buffer = MinuteReadingBuffer()
        buffer.add(reading(1, minutesAgo: 1), now: now)
        let restored = try JSONDecoder().decode(MinuteReadingBuffer.self, from: JSONEncoder().encode(buffer))
        #expect(restored == buffer)
    }
}

/// Fork feature (branch libre-1min-display): what the glucose bubble shows.
@Suite("MinuteBubbleInfo: minute reading in the glucose bubble") struct MinuteBubbleInfoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Readings every minute, `count` of them, newest `newestSecondsAgo` before now.
    private func readings(_ values: [Int], newestSecondsAgo: TimeInterval = 20) -> [MinuteGlucoseReading] {
        values.enumerated().map { index, value in
            let minutesBeforeNewest = Double(values.count - 1 - index)
            return MinuteGlucoseReading(
                id: "r\(index)",
                date: now.addingTimeInterval(-newestSecondsAgo - minutesBeforeNewest * 60),
                mgdl: value
            )
        }
    }

    @Test("Newest reading, minutes after the 5-minute reading, and 5-minute delta") func basic() throws {
        // 7 readings: 100 ... 112; newest is 112, the one 5 minutes earlier is 102.
        let list = readings([100, 102, 104, 106, 108, 110, 112])
        let fiveMinuteDate = list[3].date // 5-minute reading = 106, 3 minutes before newest
        let info = try #require(MinuteBubbleInfo.make(readings: list, lastFiveMinuteDate: fiveMinuteDate, now: now))
        #expect(info.mgdl == 112)
        #expect(info.minutesAfterFiveMinuteReading == 3)
        #expect(info.fiveMinuteDelta == 10)
    }

    @Test("Newest reading equal to the 5-minute reading gives +0") func sameAsFiveMinute() throws {
        let list = readings([100, 101])
        let info = try #require(MinuteBubbleInfo.make(readings: list, lastFiveMinuteDate: list[1].date, now: now))
        #expect(info.minutesAfterFiveMinuteReading == 0)
    }

    @Test("No delta without a reading about 5 minutes earlier") func noDelta() throws {
        let list = readings([100, 102, 104])
        let info = try #require(MinuteBubbleInfo.make(readings: list, lastFiveMinuteDate: nil, now: now))
        #expect(info.fiveMinuteDelta == nil)
        #expect(info.minutesAfterFiveMinuteReading == nil)
    }

    @Test("Stale or missing minute readings fall back (nil)") func stale() {
        #expect(MinuteBubbleInfo.make(readings: [], lastFiveMinuteDate: now, now: now) == nil)
        let old = readings([100, 101], newestSecondsAgo: 4 * 60)
        #expect(MinuteBubbleInfo.make(readings: old, lastFiveMinuteDate: now, now: now) == nil)
    }
}
