import Foundation

public enum HistoryStore {
    public static let maximumPoints = 3_000
    public static let retention: TimeInterval = 24 * 3600

    public static func pruned(_ points: [HistoryPoint], now: Date) -> [HistoryPoint] {
        var seen = Set<Date>()
        return Array(points.filter {
            $0.isValid && $0.date <= now && now.timeIntervalSince($0.date) <= retention
        }.sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }.suffix(maximumPoints))
    }

    public static func load(from url: URL, now: Date) throws -> [HistoryPoint] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Bound file size before decoding, even if the file was edited outside the app.
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        return pruned(try JSONDecoder().decode([HistoryPoint].self, from: data), now: now)
    }

    public static func save(_ points: [HistoryPoint], to url: URL, now: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pruned(points, now: now))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// One notification per crossed threshold, rearmed only by an external-power session.
public struct LowBatteryAlerts: Sendable {
    private var sent = Set<Int>()
    private var previousLevel: Double?
    public init() {}

    public mutating func evaluate(_ reading: BatteryReading) -> Int? {
        guard reading.power == .battery else {
            if reading.power == .charging || reading.power == .pluggedIn { sent.removeAll(); previousLevel = nil }
            return nil
        }
        defer { previousLevel = reading.level }
        let crossed = [5, 10, 20].filter { threshold in
            reading.level <= Double(threshold) && !sent.contains(threshold) &&
                (previousLevel == nil || previousLevel! > Double(threshold))
        }
        guard let mostUrgent = crossed.first else { return nil }
        // A jump from 25% to 4% should send one useful alert, not three.
        for threshold in [5, 10, 20] where reading.level <= Double(threshold) { sent.insert(threshold) }
        return mostUrgent
    }
}
