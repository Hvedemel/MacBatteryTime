import Foundation

/// Only learns from contiguous, awake discharge sessions. All rates are percentage points/hour.
/// Capacity alone is never a time estimate: observed time and drain are required.
public struct DischargeEstimator: Sendable {
    private var samples: [BatteryReading] = []
    private var smoothedRate: Double?
    private var lastEstimate: BatteryEstimate?
    private var lastPower: PowerState?
    public private(set) var session = UUID()
    public var maximumGap: TimeInterval = 150

    public init() {}

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothedRate = nil
        lastEstimate = nil
        lastPower = nil
        session = UUID()
    }

    public mutating func ingest(_ reading: BatteryReading) -> BatteryEstimate? {
        guard reading.power == .battery else {
            if lastPower != reading.power { reset() }
            lastPower = reading.power
            return nil
        }
        if let lastPower, lastPower != .battery { reset() }
        lastPower = .battery
        if let previous = samples.last {
            let gap = reading.date.timeIntervalSince(previous.date)
            guard gap > 0 else { return lastEstimate }
            if gap > maximumGap || previous.identity != reading.identity ||
                previous.lowPowerMode != reading.lowPowerMode || reading.level > previous.level + 0.75 {
                reset()
            }
        }
        samples.append(reading)
        samples.removeAll { reading.date.timeIntervalSince($0.date) > 30 * 60 }
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }

        let longRate = regressionRate(samples)
        let shortRate = regressionRate(samples.filter { reading.date.timeIntervalSince($0.date) <= 10 * 60 })
        let measured: Double?
        if let longRate, let shortRate { measured = shortRate * 0.7 + longRate * 0.3 }
        else { measured = shortRate ?? longRate }

        if let measured {
            if let previous = smoothedRate, let earlier = samples.dropLast().last {
                let elapsed = reading.date.timeIntervalSince(earlier.date)
                // Time-based smoothing behaves consistently at every refresh interval.
                let alpha = 1 - exp(-elapsed / 120)
                smoothedRate = previous + alpha * (measured - previous)
            } else { smoothedRate = measured }
        } else if let first = samples.first, reading.date.timeIntervalSince(first.date) >= 25 * 60 {
            // Let an old rate expire if the battery has stopped measurably discharging.
            smoothedRate = nil
        }

        let observed = smoothedRate.flatMap { BatteryReading.validSeconds(reading.level / $0 * 3600) }
        let system = reading.systemSeconds
        let seconds: Double
        let source: EstimateSource
        if let observed, let system {
            // macOS is a corroborating signal, not a veto on measured changes in workload.
            // Ignore a grossly contradictory system estimate rather than averaging it in.
            let ratio = system / observed
            if (0.4...2.5).contains(ratio) {
                seconds = observed * 0.8 + system * 0.2
                source = .blended
            } else { seconds = observed; source = .observed }
        } else if let observed { seconds = observed; source = .observed }
        else if let system { seconds = system; source = .system }
        else { lastEstimate = nil; return nil }

        guard let valid = BatteryReading.validSeconds(seconds), reading.level > 0 else {
            lastEstimate = nil
            return nil
        }
        let estimate = BatteryEstimate(seconds: valid, date: reading.date, source: source,
                                       percentPerHour: smoothedRate)
        lastEstimate = estimate
        return estimate
    }

    private func regressionRate(_ points: [BatteryReading]) -> Double? {
        guard points.count >= 4, let first = points.first, let last = points.last,
              last.date.timeIntervalSince(first.date) >= 300,
              first.level - last.level >= 2 else { return nil }
        let count = Double(points.count)
        let xs = points.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let xMean = xs.reduce(0, +) / count
        let yMean = points.reduce(0) { $0 + $1.level } / count
        var numerator = 0.0
        var denominator = 0.0
        for (index, point) in points.enumerated() {
            let x = xs[index] - xMean
            numerator += x * (point.level - yMean)
            denominator += x * x
        }
        guard denominator > 0 else { return nil }
        let rate = -numerator / denominator
        return rate.isFinite && (0.25...200).contains(rate) ? rate : nil
    }
}
