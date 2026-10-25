import Foundation
#if !BATTERYTIME_STANDALONE_TESTS
import XCTest
#endif
@testable import BatteryCore

final class BatteryCoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func reading(_ seconds: Double = 0, level: Double = 80, power: PowerState = .battery,
                         system: Double? = nil, identity: String = "A", lowPower: Bool = false) -> BatteryReading {
        BatteryReading(date: start.addingTimeInterval(seconds), current: level, maximum: 100,
                       power: power, systemSeconds: system, lowPowerMode: lowPower, identity: identity)!
    }
    private func learnedEstimator() -> DischargeEstimator {
        var estimator = DischargeEstimator()
        for index in 0...20 { _ = estimator.ingest(reading(Double(index * 30), level: 80 - Double(index) * 0.2)) }
        return estimator
    }

    func testMissingCapacityIsNeverZeroPercent() {
        XCTAssertNil(BatteryReading(date: start, current: nil, maximum: 100, power: .battery))
        XCTAssertNil(BatteryReading(date: start, current: 60, maximum: nil, power: .battery))
        XCTAssertNil(BatteryReading(date: start, current: 60, maximum: 0, power: .battery))
    }
    func testInvalidCapacityRejected() {
        for value in [Double.nan, .infinity, -1, 200] {
            XCTAssertNil(BatteryReading(date: start, current: value, maximum: 100, power: .battery))
        }
    }
    func testCapacityNormalizedCorrectly() {
        XCTAssertEqual(BatteryReading(date: start, current: 2_000, maximum: 4_000, power: .battery)?.percentage, 50)
        XCTAssertEqual(reading(level: 0).percentage, 0)
    }
    func testPercentageCapacityCannotBecomeHealth() {
        let value = BatteryReading(date: start, current: 80, maximum: 100, power: .battery,
                                   fullCapacity: 100, designCapacity: 4_382)!
        XCTAssertNil(value.capacityHealth)
        XCTAssertNil(value.fullCapacity)
    }
    func testHealthRequiresConsistentCapacity() {
        let value = BatteryReading(date: start, current: 80, maximum: 100, power: .battery,
                                   fullCapacity: 3_600, designCapacity: 4_000)!
        XCTAssertEqual(value.capacityHealth, 90)
    }
    func testSystemSentinelsAndOutliersRejected() {
        for seconds in [-2.0, -1, 0, .infinity, .nan, 300_000] {
            XCTAssertNil(BatteryReading.validSeconds(seconds))
        }
        XCTAssertEqual(BatteryReading.validSeconds(3600), 3600)
    }
    func testNoEstimateFromPercentageAlone() {
        var estimator = DischargeEstimator()
        XCTAssertNil(estimator.ingest(reading()))
        XCTAssertNil(estimator.ingest(reading(30, level: 79)))
    }
    func testFlatBatteryHasNoInventedEstimate() {
        var estimator = DischargeEstimator()
        for index in 0...60 { XCTAssertNil(estimator.ingest(reading(Double(index * 30)))) }
    }
    func testSystemEstimateAvailableImmediately() {
        var estimator = DischargeEstimator()
        let result = estimator.ingest(reading(system: 14_400))
        XCTAssertEqual(result?.seconds, 14_400)
        XCTAssertEqual(result?.source, .system)
    }
    func testObservedRateMatchesKnownDrain() throws {
        var estimator = learnedEstimator()
        let result = try XCTUnwrap(estimator.ingest(reading(630, level: 75.8)))
        XCTAssertEqual(result.percentPerHour!, 24, accuracy: 0.001)
        XCTAssertEqual(result.seconds, 75.8 / 24 * 3600, accuracy: 1)
        XCTAssertEqual(result.source, .observed)
    }
    func testQuantizedOnePercentStepsCanLearn() {
        var estimator = DischargeEstimator()
        var result: BatteryEstimate?
        for index in 0...40 { result = estimator.ingest(reading(Double(index * 30), level: 90 - Double(index / 10))) }
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.percentPerHour!, 12, accuracy: 2)
    }
    func testAgreeingSystemSignalIsBlended() throws {
        var estimator = learnedEstimator()
        let result = try XCTUnwrap(estimator.ingest(reading(630, level: 75.8, system: 12_000)))
        XCTAssertEqual(result.source, .blended)
        XCTAssertEqual(result.seconds, (75.8 / 24 * 3600) * 0.8 + 12_000 * 0.2, accuracy: 1)
    }
    func testContradictorySystemSignalDoesNotOverrideObservedDrain() {
        var estimator = learnedEstimator()
        let result = estimator.ingest(reading(630, level: 75.8, system: 100_000))
        XCTAssertEqual(result?.source, .observed)
    }
    func testWorkloadChangeAdapts() throws {
        var estimator = learnedEstimator()
        var result: BatteryEstimate?
        // Double the consumption from 24 to 48 percentage points/hour.
        for index in 1...40 { result = estimator.ingest(reading(600 + Double(index * 30), level: 76 - Double(index) * 0.4)) }
        let rate = try XCTUnwrap(result?.percentPerHour)
        XCTAssertGreaterThan(rate, 43)
        XCTAssertLessThan(rate, 49)
    }
    func testChargingClearsDischargeEstimate() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, level: 76, power: .charging, system: 5_000)))
        XCTAssertNil(estimator.ingest(reading(660, level: 76)))
    }
    func testAdapterWithoutChargingHasNoCountdown() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, power: .pluggedIn, system: 5_000)))
    }
    func testUnknownPowerHasNoCountdown() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, power: .unknown)))
    }
    func testSleepGapResetsLearning() {
        var estimator = learnedEstimator()
        let session = estimator.session
        XCTAssertNil(estimator.ingest(reading(7_200, level: 70)))
        XCTAssertNotEqual(estimator.session, session)
    }
    func testExplicitWakeResetDoesNotReuseOldDrain() {
        var estimator = learnedEstimator()
        estimator.reset()
        XCTAssertNil(estimator.ingest(reading(660, level: 75)))
    }
    func testReplacementBatteryResetsLearning() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, level: 76, identity: "B")))
    }
    func testCapacityIncreaseResetsLearning() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, level: 80)))
    }
    func testLowPowerModeChangeResetsLearning() {
        var estimator = learnedEstimator()
        XCTAssertNil(estimator.ingest(reading(630, level: 76, lowPower: true)))
    }
    func testOutOfOrderSampleDoesNotDistortRate() {
        var estimator = learnedEstimator()
        let a = estimator.ingest(reading(630, level: 75.8))
        let b = estimator.ingest(reading(620, level: 20))
        XCTAssertEqual(a, b)
    }
    func testTwoMinuteRefreshStillLearns() {
        var estimator = DischargeEstimator()
        estimator.maximumGap = 300
        var result: BatteryEstimate?
        for index in 0...6 { result = estimator.ingest(reading(Double(index * 120), level: 80 - Double(index))) }
        XCTAssertNotNil(result)
    }
    func testStableAdapterSessionGroupsHistory() {
        var estimator = DischargeEstimator()
        _ = estimator.ingest(reading(power: .pluggedIn))
        let session = estimator.session
        _ = estimator.ingest(reading(30, power: .pluggedIn))
        XCTAssertEqual(estimator.session, session)
    }
    func testCountdownAndEmptyDate() {
        let value = BatteryEstimate(seconds: 3600, date: start, source: .system)
        XCTAssertEqual(value.remaining(at: start.addingTimeInterval(120)), 3480)
        XCTAssertEqual(value.remaining(at: start.addingTimeInterval(4_000)), 0)
        XCTAssertEqual(value.remaining(at: start.addingTimeInterval(-100)), 3600)
        XCTAssertEqual(value.emptyDate, start.addingTimeInterval(3600))
    }
    func testTimeFormatting() {
        XCTAssertEqual(TimeText.compact(5 * 3600 + 42 * 60), "5h 42m")
        XCTAssertEqual(TimeText.full(5 * 3600 + 42 * 60), "5 hours 42 minutes")
        XCTAssertEqual(TimeText.full(60), "1 minute")
        XCTAssertEqual(TimeText.compact(0), "0m")
    }
    func testThresholdAlertsOncePerDischarge() {
        var alerts = LowBatteryAlerts()
        XCTAssertNil(alerts.evaluate(reading(level: 21)))
        XCTAssertEqual(alerts.evaluate(reading(30, level: 20)), 20)
        XCTAssertNil(alerts.evaluate(reading(60, level: 19)))
        XCTAssertEqual(alerts.evaluate(reading(90, level: 10)), 10)
        XCTAssertEqual(alerts.evaluate(reading(120, level: 5)), 5)
        XCTAssertNil(alerts.evaluate(reading(150, level: 4)))
        XCTAssertNil(alerts.evaluate(reading(180, level: 8, power: .charging)))
        XCTAssertEqual(alerts.evaluate(reading(210, level: 8)), 10)
    }
    func testThresholdJumpSendsOnlyMostUrgentAlert() {
        var alerts = LowBatteryAlerts()
        XCTAssertNil(alerts.evaluate(reading(level: 25)))
        XCTAssertEqual(alerts.evaluate(reading(30, level: 4)), 5)
        XCTAssertNil(alerts.evaluate(reading(60, level: 4)))
    }
    func testHistoryRoundTripsAndPrunes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let points = [HistoryPoint(date: start, level: 50, power: .battery, estimateSeconds: 7200, session: UUID()),
                      HistoryPoint(date: start.addingTimeInterval(-90_000), level: 90, power: .battery, estimateSeconds: nil, session: UUID())]
        try HistoryStore.save(points, to: url, now: start)
        XCTAssertEqual(try HistoryStore.load(from: url, now: start), [points[0]])
    }
    func testInvalidFutureAndDuplicateHistoryRemoved() {
        let session = UUID()
        let make: (Date, Double) -> HistoryPoint = { date, level in
            HistoryPoint(date: date, level: level, power: .battery, estimateSeconds: nil, session: session)
        }
        let valid = make(start, 80)
        let points = [valid, valid, make(start, .nan), make(start.addingTimeInterval(1), 50)]
        XCTAssertEqual(HistoryStore.pruned(points, now: start), [valid])
    }
    func testHistoryBounded() {
        let points = (0..<4_000).map { index in
            HistoryPoint(date: start.addingTimeInterval(-Double(index * 15)), level: 50,
                         power: .battery, estimateSeconds: nil, session: UUID())
        }
        XCTAssertEqual(HistoryStore.pruned(points, now: start).count, 3_000)
    }
    func testCorruptHistoryRaisesAnError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        try Data("{bad json".utf8).write(to: url)
        XCTAssertThrowsError(try HistoryStore.load(from: url, now: start))
    }
    func testDecodedInvalidEstimateIsDiscarded() throws {
        let json = """
        [{"date":\(start.timeIntervalSinceReferenceDate),"level":80,"power":"battery","estimateSeconds":-100,"session":"D7214AEF-8512-46B1-B94D-C7C8A8849AB4"}]
        """
        let points = try JSONDecoder().decode([HistoryPoint].self, from: Data(json.utf8))
        XCTAssertEqual(HistoryStore.pruned(points, now: start), [])
    }
}
