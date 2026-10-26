import Foundation

/// Learns awake discharge rates from time-separated samples. No CPU/GPU polling is needed:
/// changes in those workloads are reflected in observed drain and the macOS time signal.
public struct DischargeEstimator: Sendable {
    private var samples: [BatteryReading] = []
    private var previousReading: BatteryReading?
    private var smoothedRate: Double?
    private var systemRate: Double?
    private var systemSignalDate: Date?
    private var lastDropDate: Date?
    private var lastEstimate: BatteryEstimate?
    private var lastPower: PowerState?
    public private(set) var session = UUID()
    public var maximumGap: TimeInterval = 150

    public init() {}

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        previousReading = nil
        smoothedRate = nil
        systemRate = nil
        systemSignalDate = nil
        lastDropDate = nil
        lastEstimate = nil
        lastPower = nil
        session = UUID()
    }

    public mutating func ingest(_ reading: BatteryReading) -> BatteryEstimate? {
        guard reading.power == .battery else {
            if lastPower != reading.power || previousReading?.identity != reading.identity { reset() }
            previousReading = reading
            lastPower = reading.power
            return nil
        }
        if let lastPower, lastPower != .battery { reset() }
        if let previous = previousReading {
            let gap = reading.date.timeIntervalSince(previous.date)
            if gap == 0, previous == reading { return lastEstimate }
            if gap <= 0 || gap > maximumGap || previous.identity != reading.identity ||
                previous.lowPowerMode != reading.lowPowerMode || reading.level > previous.level + 0.75 {
                reset()
            }
        }
        let elapsed = previousReading.map { reading.date.timeIntervalSince($0.date) }
        if lastDropDate == nil || reading.level < (previousReading?.level ?? reading.level) - 0.001 {
            lastDropDate = reading.date
        }
        previousReading = reading
        lastPower = .battery
        guard reading.level > 0 else { lastEstimate = nil; return nil }

        // Event bursts and repeated Refresh clicks must not overweight one instant of use.
        if samples.last.map({ reading.date.timeIntervalSince($0.date) >= 15 }) ?? true {
            samples.append(reading)
        }
        samples.removeAll { reading.date.timeIntervalSince($0.date) > 30 * 60 }
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }
        let recentStart = samples.firstIndex { reading.date.timeIntervalSince($0.date) <= 8 * 60 } ?? samples.endIndex
        let minimumDrop = smoothedRate == nil ? 2.0 : 0.75
        let long = regressionRate(samples[...], minimumDrop: 2)
        let recent = regressionRate(samples[recentStart...], minimumDrop: minimumDrop)
        var measured = recent ?? long
        if let recent, let long {
            let changed = recent / long > 1.4 || recent / long < 0.7
            measured = recent * (changed ? 0.9 : 0.7) + long * (changed ? 0.1 : 0.3)
        }
        let flatDuration = reading.date.timeIntervalSince(lastDropDate ?? reading.date)
        if flatDuration >= 300, let rate = measured {
            // A rounded percentage that hasn't fallen for this long sets an upper bound,
            // not proof of zero consumption. Avoid reusing an old high-load rate at idle.
            measured = min(rate, 3600 / flatDuration)
        }
        if flatDuration >= 600 {
            smoothedRate = nil
        } else if let measured {
            if let old = smoothedRate, let elapsed, elapsed > 0 {
                smoothedRate = old + (1 - exp(-elapsed / 120)) * (measured - old)
            } else { smoothedRate = measured }
        }

        let observed = smoothedRate.flatMap { BatteryReading.validSeconds(reading.level / $0 * 3600) }
        let system = filteredSystemSeconds(reading)
        let seconds: Double
        let source: EstimateSource
        if let observed, let system {
            let ratio = system / observed
            if (0.4...2.5).contains(ratio) {
                seconds = observed * 0.8 + system * 0.2
                source = .blended
            } else { seconds = observed; source = .observed }
        } else if let observed { seconds = observed; source = .observed }
        else if let system { seconds = system; source = .system }
        else { lastEstimate = nil; return nil }
        guard let valid = BatteryReading.validSeconds(seconds) else { lastEstimate = nil; return nil }
        let estimate = BatteryEstimate(seconds: valid, date: reading.date, source: source,
                                       percentPerHour: smoothedRate)
        lastEstimate = estimate
        return estimate
    }

    private mutating func filteredSystemSeconds(_ reading: BatteryReading) -> Double? {
        guard let seconds = reading.systemSeconds else { return nil }
        let currentRate = reading.level / seconds * 3600
        if let previous = systemRate, let date = systemSignalDate {
            let elapsed = reading.date.timeIntervalSince(date)
            if elapsed > 0 && elapsed <= maximumGap {
                systemRate = previous + (1 - exp(-elapsed / 120)) * (currentRate - previous)
            } else { systemRate = currentRate }
        } else { systemRate = currentRate }
        systemSignalDate = reading.date
        return systemRate.flatMap { BatteryReading.validSeconds(reading.level / $0 * 3600) }
    }

    private func regressionRate(_ points: ArraySlice<BatteryReading>, minimumDrop: Double) -> Double? {
        guard points.count >= 4, let first = points.first, let last = points.last,
              last.date.timeIntervalSince(first.date) >= 300,
              first.level - last.level >= minimumDrop else { return nil }
        // Aggregate moments without allocating separate x/y arrays on every update.
        var sx = 0.0, sy = 0.0, sxy = 0.0, sxx = 0.0
        for point in points {
            let x = point.date.timeIntervalSince(first.date) / 3600
            sx += x; sy += point.level; sxy += x * point.level; sxx += x * x
        }
        let count = Double(points.count)
        let denominator = sxx - sx * sx / count
        guard denominator > 0 else { return nil }
        let rate = -(sxy - sx * sy / count) / denominator
        return rate.isFinite && (0.25...200).contains(rate) ? rate : nil
    }
}
