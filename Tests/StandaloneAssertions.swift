import Foundation
#if BATTERYTIME_STANDALONE_TESTS
class XCTestCase {}
private enum UnwrapFailure: Error { case missing }
nonisolated(unsafe) var failures = 0
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
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { record("Expected true", file: file, line: line) }
}
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value { record("Expected false", file: file, line: line) }
}
#endif
