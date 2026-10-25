import Foundation

public enum PowerState: String, Codable, Sendable {
    case battery, charging, pluggedIn, unknown

    public var title: String {
        switch self {
        case .battery: return "On battery"
        case .charging: return "Charging"
        case .pluggedIn: return "Power adapter"
        case .unknown: return "Power source unavailable"
        }
    }
}

public struct BatteryReading: Codable, Sendable, Equatable {
    public let date: Date
    public let level: Double
    public let power: PowerState
    public let systemSeconds: Double?
    public let lowPowerMode: Bool
    public let identity: String
    public let health: String?
    public let cycles: Int?
    public let fullCapacity: Double?
    public let designCapacity: Double?

    public init?(date: Date, current: Double?, maximum: Double?, power: PowerState,
                 systemSeconds: Double? = nil, lowPowerMode: Bool = false,
                 identity: String = "internal", health: String? = nil, cycles: Int? = nil,
                 fullCapacity: Double? = nil, designCapacity: Double? = nil) {
        guard let current, let maximum, current.isFinite, maximum.isFinite,
              maximum > 0, current >= 0, current <= maximum * 1.01 else { return nil }
        self.date = date
        level = min(100, current / maximum * 100)
        self.power = power
        self.systemSeconds = Self.validSeconds(systemSeconds)
        self.lowPowerMode = lowPowerMode
        self.identity = identity
        self.health = health
        self.cycles = cycles.flatMap { (0...100_000).contains($0) ? $0 : nil }
        // Percentage-normalized capacity (often 100) must never be labeled mAh
        // or compared with the physical design capacity.
        if let fullCapacity, let designCapacity, fullCapacity.isFinite, designCapacity.isFinite,
           fullCapacity > 100, designCapacity > 100, fullCapacity <= designCapacity * 1.2 {
            self.fullCapacity = fullCapacity
            self.designCapacity = designCapacity
        } else {
            self.fullCapacity = nil
            self.designCapacity = nil
        }
    }

    public static func validSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 72 * 3600 else { return nil }
        return value
    }

    public var percentage: Int { Int(level.rounded()) }
    public var capacityHealth: Int? {
        guard let fullCapacity, let designCapacity else { return nil }
        return min(100, Int((fullCapacity / designCapacity * 100).rounded()))
    }
}

public enum EstimateSource: String, Codable, Sendable {
    case system, observed, blended

    public var title: String {
        switch self {
        case .system: return "macOS estimate"
        case .observed: return "Based on observed use"
        case .blended: return "Observed use + macOS"
        }
    }
}

public struct BatteryEstimate: Codable, Sendable, Equatable {
    public let seconds: Double
    public let date: Date
    public let source: EstimateSource
    public let percentPerHour: Double?

    public init(seconds: Double, date: Date, source: EstimateSource, percentPerHour: Double? = nil) {
        self.seconds = seconds
        self.date = date
        self.source = source
        self.percentPerHour = percentPerHour
    }

    public func remaining(at now: Date) -> Double { max(0, seconds - max(0, now.timeIntervalSince(date))) }
    public var emptyDate: Date { date.addingTimeInterval(seconds) }
}

public struct HistoryPoint: Codable, Sendable, Identifiable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let level: Double
    public let power: PowerState
    public let estimateSeconds: Double?
    public let session: UUID

    public init(date: Date, level: Double, power: PowerState, estimateSeconds: Double?, session: UUID) {
        self.date = date
        self.level = level
        self.power = power
        self.estimateSeconds = BatteryReading.validSeconds(estimateSeconds)
        self.session = session
    }

    public var isValid: Bool {
        level.isFinite && (0...100).contains(level) &&
            (estimateSeconds == nil || BatteryReading.validSeconds(estimateSeconds) != nil)
    }
}

public enum TimeText {
    public static func compact(_ seconds: Double) -> String {
        let minutes = max(0, Int(ceil(max(0, seconds) / 60)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    public static func full(_ seconds: Double) -> String {
        let minutes = max(0, Int(ceil(max(0, seconds) / 60)))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) \(rest == 1 ? "minute" : "minutes")" }
        return "\(hours) \(hours == 1 ? "hour" : "hours") \(rest) \(rest == 1 ? "minute" : "minutes")"
    }
}
