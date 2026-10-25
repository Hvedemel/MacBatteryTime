import Foundation
#if BATTERYTIME_STANDALONE_TESTS
class XCTestCase {}
private enum UnwrapFailure: Error { case missing }
nonisolated(unsafe) private var failures = 0
private func record(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { record("Expected nil, got \(String(describing: value))", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { record("Expected a value", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { record("\(a) != \(b)", file: file, line: line) }
}
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    if !a.isFinite || abs(a-b) > accuracy { record("\(a) differs from \(b) by more than \(accuracy)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a == b { record("Unexpected equal values", file: file, line: line) }
}
func XCTAssertGreaterThan(_ a: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
    if !(a > b) { record("Expected \(a) > \(b)", file: file, line: line) }
}
func XCTAssertLessThan(_ a: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
    if !(a < b) { record("Expected \(a) < \(b)", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { record("Missing required value", file: file, line: line); throw UnwrapFailure.missing }
    return value
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); record("Expected an error", file: file, line: line) } catch {}
}
@main enum RegressionRunner {
    static func main() {
        let suite = BatteryCoreTests()
        suite.testMissingCapacityIsNeverZeroPercent()
        suite.testInvalidCapacityRejected()
        suite.testCapacityNormalizedCorrectly()
        suite.testPercentageCapacityCannotBecomeHealth()
        suite.testHealthRequiresConsistentCapacity()
        suite.testSystemSentinelsAndOutliersRejected()
        suite.testNoEstimateFromPercentageAlone()
        suite.testFlatBatteryHasNoInventedEstimate()
        suite.testSystemEstimateAvailableImmediately()
        do { try suite.testObservedRateMatchesKnownDrain() } catch { print("FAIL testObservedRateMatchesKnownDrain: \(error)"); failures += 1 }
        suite.testQuantizedOnePercentStepsCanLearn()
        do { try suite.testAgreeingSystemSignalIsBlended() } catch { print("FAIL testAgreeingSystemSignalIsBlended: \(error)"); failures += 1 }
        suite.testContradictorySystemSignalDoesNotOverrideObservedDrain()
        do { try suite.testWorkloadChangeAdapts() } catch { print("FAIL testWorkloadChangeAdapts: \(error)"); failures += 1 }
        suite.testChargingClearsDischargeEstimate()
        suite.testAdapterWithoutChargingHasNoCountdown()
        suite.testUnknownPowerHasNoCountdown()
        suite.testSleepGapResetsLearning()
        suite.testExplicitWakeResetDoesNotReuseOldDrain()
        suite.testReplacementBatteryResetsLearning()
        suite.testCapacityIncreaseResetsLearning()
        suite.testLowPowerModeChangeResetsLearning()
        suite.testOutOfOrderSampleDoesNotDistortRate()
        suite.testTwoMinuteRefreshStillLearns()
        suite.testStableAdapterSessionGroupsHistory()
        suite.testCountdownAndEmptyDate()
        suite.testTimeFormatting()
        suite.testThresholdAlertsOncePerDischarge()
        suite.testThresholdJumpSendsOnlyMostUrgentAlert()
        do { try suite.testHistoryRoundTripsAndPrunes() } catch { print("FAIL testHistoryRoundTripsAndPrunes: \(error)"); failures += 1 }
        suite.testInvalidFutureAndDuplicateHistoryRemoved()
        suite.testHistoryBounded()
        do { try suite.testCorruptHistoryRaisesAnError() } catch { print("FAIL testCorruptHistoryRaisesAnError: \(error)"); failures += 1 }
        do { try suite.testDecodedInvalidEstimateIsDiscarded() } catch { print("FAIL testDecodedInvalidEstimateIsDiscarded: \(error)"); failures += 1 }
        print("34 regression tests completed; \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
#endif
