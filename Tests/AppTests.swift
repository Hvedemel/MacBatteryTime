import AppKit
import Foundation
import IOKit.ps

private actor ReadGate {
    private var pending: [CheckedContinuation<BatteryReport, Never>] = []
    private(set) var count = 0
    func read() async -> BatteryReport {
        count += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func finish(_ report: BatteryReport) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: report)
    }
}

private actor PermissionGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private(set) var requested = false
    func request() async -> Bool {
        requested = true
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ granted: Bool) { pending?.resume(returning: granted); pending = nil }
}

@MainActor private final class WeakMonitorReference {
    weak var value: BatteryMonitor?
    init(_ value: BatteryMonitor?) { self.value = value }
}

private enum TestFailure: Error { case condition(String) }
@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.condition(message) }
}
@MainActor
private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw TestFailure.condition("Timed out waiting for the expected state")
}

@MainActor
private final class AppTestSuite {
    let root: URL
    private var suites: [String] = []
    init(root: URL) { self.root = root }
    private func url() -> URL { root.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json") }
    private func defaults() -> UserDefaults {
        let name = "dk.batterytime.tests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    func cleanup() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
    }
    private func report(_ power: PowerState = .battery, level: Double = 80, seconds: Double? = 14_400,
                        lowPower: Bool = false, date: Date = Date()) -> BatteryReport {
        BatteryReport(availability: .available,
            reading: BatteryReading(date: date, current: level, maximum: 100, power: power,
                                    systemSeconds: seconds, lowPowerMode: lowPower), message: "fixture")
    }
    private func description(_ power: String = kIOPSBatteryPowerValue, level: Any = 80,
                             charging: Bool = false) -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: level,
         kIOPSMaxCapacityKey: 100, kIOPSPowerSourceStateKey: power,
         kIOPSIsChargingKey: charging, kIOPSIsPresentKey: true]
    }
    private func decode(_ sources: [[String: Any]?], global: Double = -1) -> BatteryReport {
        BatteryReader.decode(sources, at: Date(), lowPowerMode: false,
                             globalSeconds: { global }, registry: { ("test", 123) })
    }

    func testRealNativeReader() throws {
        let value = BatteryReader.read()
        try expect(value.availability != .available || value.reading != nil, "Available report must contain a reading")
        if let reading = value.reading {
            try expect((0...100).contains(reading.level), "Native battery percentage out of range")
        }
    }
    func testDesktopAndAbsentBattery() throws {
        try expect(decode([]).availability == .noBattery, "Desktop should report no internal battery")
        var absent = description(); absent[kIOPSIsPresentKey] = false
        try expect(decode([absent]).availability == .noBattery, "Absent battery must be skipped")
        try expect(decode([[kIOPSTypeKey: kIOPSUPSType]]).availability == .noBattery, "A UPS is not an internal battery")
    }
    func testUnavailableDescriptorIsNotDesktop() throws {
        try expect(decode([nil]).availability == .unavailable, "Failed descriptor must not claim desktop")
        try expect(decode([[:]]).availability == .unavailable, "Malformed descriptor must remain unavailable")
    }
    func testMalformedCapacityAndBooleanRejected() throws {
        var missing = description(); missing.removeValue(forKey: kIOPSCurrentCapacityKey)
        try expect(decode([missing]).availability == .unavailable, "Missing capacity must not become 0%")
        try expect(decode([description(level: true)]).availability == .unavailable, "Bool is not numeric charge")
        var zero = description(); zero[kIOPSMaxCapacityKey] = 0
        try expect(decode([zero]).availability == .unavailable, "Zero maximum capacity must be rejected")
    }
    func testSourceTimeUnitsAndGlobalFallback() throws {
        var source = description(); source[kIOPSTimeToEmptyKey] = 42
        try expect(decode([source], global: 20_000).reading?.systemSeconds == 2520, "Per-source minutes must be converted to seconds")
        source[kIOPSTimeToEmptyKey] = -1
        try expect(decode([source], global: 3600).reading?.systemSeconds == 3600, "Invalid source time should fall back to global seconds")
        try expect(decode([source], global: -2).reading?.systemSeconds == nil, "Unlimited system sentinel must be ignored")
    }
    func testChargingAndInconsistentPower() throws {
        let charging = decode([description(kIOPSACPowerValue, charging: true)], global: 3600)
        try expect(charging.reading?.power == .charging && charging.reading?.systemSeconds == nil, "Charging cannot have discharge runtime")
        let full = decode([description(kIOPSACPowerValue, level: 100)])
        try expect(full.reading?.power == .pluggedIn && full.reading?.percentage == 100, "Full external-power battery state lost")
        try expect(decode([description(charging: true)]).reading?.power == .unknown, "Contradictory charging/battery state should not claim charging")
    }
    func testUnusedGlobalSignalNotQueried() throws {
        var queries = 0
        var source = description(); source[kIOPSTimeToEmptyKey] = 42
        _ = BatteryReader.decode([source], at: Date(), lowPowerMode: false,
                                 globalSeconds: { queries += 1; return 3600 }, registry: { (nil, nil) })
        _ = BatteryReader.decode([description(kIOPSACPowerValue)], at: Date(), lowPowerMode: false,
                                 globalSeconds: { queries += 1; return 3600 }, registry: { (nil, nil) })
        try expect(queries == 0, "Unused global time API should not be called")
    }
    func testMenuStatesAndExpiredEstimates() throws {
        let now = Date()
        let estimate = BatteryEstimate(seconds: 14_400, date: now, source: .system)
        let battery = StatusPresentation.make(report: report(date: now), estimate: estimate, now: now, showTime: true, maximumAge: 150)
        try expect(battery.title == " 80% · 4h 0m", "Wrong live status title")
        let hidden = StatusPresentation.make(report: report(date: now), estimate: estimate, now: now, showTime: false, maximumAge: 150)
        try expect(hidden.title == " 80%", "Menu preference ignored")
        let stale = StatusPresentation.make(report: report(date: now), estimate: estimate, now: now.addingTimeInterval(200), showTime: true, maximumAge: 150)
        try expect(stale.title == " 80% · …", "Menu must not show stale time")
        let charging = StatusPresentation.make(report: report(.charging), estimate: estimate, now: now, showTime: true, maximumAge: 150)
        try expect(charging.title.contains("Charging") && !charging.toolTip.contains("remaining"), "Charging tooltip leaked discharge estimate")
        let low = StatusPresentation.make(report: report(level: 4), estimate: nil, now: now, showTime: true, maximumAge: 150)
        try expect(low.symbol == "battery.0percent", "Low-battery menu symbol incorrect")
        let none = StatusPresentation.make(report: BatteryReport(availability: .noBattery, reading: nil, message: "none"), estimate: nil, now: now, showTime: true, maximumAge: 150)
        try expect(none.title == " No battery", "Desktop menu title incorrect")
    }
    func testRefreshRequestsCoalesceWithoutLosingPowerChange() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        monitor.start()
        try await eventually { await gate.count == 1 }
        for _ in 0..<10 { monitor.refresh() }
        await gate.finish(report())
        try await eventually { await gate.count == 2 }
        try expect(monitor.report.reading == nil, "A superseded read was published")
        await gate.finish(report(.charging))
        try await eventually { monitor.report.reading?.power == .charging }
        try expect(monitor.estimate == nil, "Charging retained an estimate")
        await monitor.stop()
    }
    func testStopDropsLateReadAndIgnoresWake() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        monitor.start()
        try await eventually { await gate.count == 1 }
        await monitor.stop()
        await gate.finish(report())
        monitor.didWake(); monitor.refresh()
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(monitor.report.reading == nil, "Stopped monitor published a late read")
        let count = await gate.count
        try expect(count == 1, "Stopped monitor restarted itself")
    }
    func testClearDropsReadFromPreviousHistorySession() async throws {
        let gate = ReadGate()
        let file = url()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: file, observeSystem: false, read: { await gate.read() })
        monitor.start()
        try await eventually { await gate.count == 1 }
        monitor.clearHistory()
        try await eventually { await gate.count == 2 }
        await gate.finish(report(level: 90))
        await gate.finish(report(level: 40))
        try await eventually { monitor.report.reading?.percentage == 40 }
        try expect(monitor.history.allSatisfy { $0.level == 40 }, "Canceled sample repopulated cleared history")
        await monitor.stop()
        let stored = try HistoryStore.load(from: file, now: Date())
        try expect(stored.allSatisfy { $0.level == 40 }, "Older asynchronous save overwrote cleared history")
    }
    func testSleepWakeResetsEstimate() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        monitor.start()
        try await eventually { await gate.count == 1 }
        await gate.finish(report())
        try await eventually { monitor.estimate != nil }
        monitor.willSleep(); monitor.refresh()
        try expect(monitor.estimate == nil, "Sleep didn't clear estimate")
        monitor.didWake()
        try await eventually { await gate.count == 2 }
        await gate.finish(report(level: 79, seconds: nil))
        try await eventually { monitor.report.reading?.percentage == 79 }
        try expect(monitor.estimate == nil, "Wake reused pre-sleep consumption")
        await monitor.stop()
    }
    func testPowerModeChangeDropsInFlightOldMode() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        monitor.start()
        try await eventually { await gate.count == 1 }
        monitor.powerModeChanged()
        try await eventually { await gate.count == 2 }
        await gate.finish(report())
        await gate.finish(report(seconds: nil, lowPower: true))
        try await eventually { monitor.report.reading?.lowPowerMode == true }
        try expect(monitor.estimate == nil, "Old mode supplied a stale estimate")
        await monitor.stop()
    }
    func testStartupHistoryMergeAndCleanShutdown() async throws {
        let file = url()
        let point = HistoryPoint(date: Date().addingTimeInterval(-60), level: 90, power: .battery,
                                 estimateSeconds: 14_400, session: UUID())
        try HistoryStore.save([point], to: file, now: Date())
        let value = report(level: 80)
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: file, observeSystem: false, read: { value })
        monitor.start()
        try await eventually { monitor.history.count == 2 }
        await monitor.stop()
        let stored = try HistoryStore.load(from: file, now: Date())
        try expect(stored.count == 2 && stored.first == point, "Startup/final write lost saved history")
    }
    func testWriteOrderingSurvivesClockRollback() async throws {
        let store = HistoryPersistence(url: url())
        let now = Date()
        let a = HistoryPoint(date: now, level: 60, power: .battery, estimateSeconds: nil, session: UUID())
        _ = await store.save([a], revision: 2, now: now)
        _ = await store.save([], revision: 1, now: now.addingTimeInterval(5))
        var loaded = await store.load(now: now)
        try expect(loaded.points == [a], "Older revision overwrote newer history")
        let earlier = now.addingTimeInterval(-100)
        let b = HistoryPoint(date: earlier, level: 50, power: .battery, estimateSeconds: nil, session: UUID())
        _ = await store.save([b], revision: 3, now: earlier)
        loaded = await store.load(now: earlier)
        try expect(loaded.points == [b], "Clock rollback suppressed a newer write")
    }
    func testWriteFailureIsReported() async throws {
        let file = url()
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = HistoryPersistence(url: file)
        let error = await store.save([], revision: 1, now: Date())
        try expect(error != nil, "Failed write must produce an error")
    }
    func testCorruptHistoryLoadsWithoutCrash() async throws {
        let file = url()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad json".utf8).write(to: file)
        let store = HistoryPersistence(url: file)
        let loaded = await store.load(now: Date())
        try expect(loaded.error != nil && loaded.points.isEmpty, "Corrupt history did not fail gracefully")
    }
    func testInvalidRefreshIntervalIsNormalized() async throws {
        let value = report()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { value })
        for interval in [-1.0, 0, 17, .nan, .infinity] {
            monitor.refreshInterval = interval
            try expect(monitor.refreshInterval == 30, "Invalid interval was accepted")
        }
        for interval in [15.0, 60, 120] {
            monitor.refreshInterval = interval
            try expect(monitor.refreshInterval == interval, "Supported interval was rejected")
        }
        await monitor.stop()
    }
    func testTurningAlertsOffWinsOverPendingPermission() async throws {
        let gate = PermissionGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false,
                                     requestAlertPermission: { await gate.request() })
        monitor.setAlerts(true)
        try await eventually { await gate.requested }
        monitor.setAlerts(false)
        await gate.finish(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(!monitor.alertsEnabled && monitor.notificationMessage == "Alerts are off.", "Late approval re-enabled alerts")
        await monitor.stop()
    }
    func testNotificationPermissionFailureIsHandled() async throws {
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false,
            requestAlertPermission: { throw CocoaError(.userCancelled) })
        monitor.setAlerts(true)
        try await eventually { monitor.notificationMessage.contains("unavailable") }
        try expect(!monitor.alertsEnabled, "Permission failure enabled alerts")
        await monitor.stop()
    }
    func testPendingReadStillRefreshesMenuFreshness() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        let date = Date()
        var now = date
        var title = ""
        monitor.onChange = { [weak monitor] in
            guard let monitor else { return }
            title = StatusPresentation.make(report: monitor.report, estimate: monitor.estimate, now: now,
                                             showTime: true, maximumAge: 150).title
        }
        monitor.start()
        try await eventually { await gate.count == 1 }
        await gate.finish(report(date: date))
        try await eventually { title.contains("4h") }
        now = date.addingTimeInterval(200)
        monitor.refresh()
        try expect(title == " 80% · …", "A pending read left stale runtime in the menu")
        try await eventually { await gate.count == 2 }
        await monitor.stop()
        await gate.finish(report())
    }
    func testPowerNotificationBurstIsBounded() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false,
                                     read: { await gate.read() }, notificationInterval: 0.05)
        monitor.start()
        try await eventually { await gate.count == 1 }
        await gate.finish(report())
        try await eventually { monitor.report.reading != nil }
        monitor.powerSourceChanged()
        try await eventually { await gate.count == 2 }
        for _ in 0..<100 { monitor.powerSourceChanged() }
        await gate.finish(report(.pluggedIn))
        try await eventually { await gate.count == 3 }
        await gate.finish(report(.charging))
        try await eventually { monitor.report.reading?.power == .charging }
        let count = await gate.count
        try expect(count == 3, "Notification burst wasn't coalesced")
        await monitor.stop()
    }
    func testStopCancelsTrailingPowerNotification() async throws {
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false,
                                     read: { await gate.read() }, notificationInterval: 0.05)
        monitor.start()
        try await eventually { await gate.count == 1 }
        await gate.finish(report())
        try await eventually { monitor.report.reading != nil }
        monitor.powerSourceChanged()
        try await eventually { await gate.count == 2 }
        await gate.finish(report(.charging))
        try await eventually { monitor.report.reading?.power == .charging }
        monitor.powerSourceChanged()
        await monitor.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await gate.count
        try expect(count == 2, "Stopped monitor retained a deferred read")
    }
    func testBackgroundPowerNotificationUsesMainActor() async throws {
        let center = NotificationCenter()
        let sleep = Notification.Name("BatteryTimeTestSleep")
        let wake = Notification.Name("BatteryTimeTestWake")
        let gate = ReadGate()
        let monitor = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { await gate.read() })
        monitor.start()
        monitor.observeNotification(center, name: sleep) { $0.willSleep() }
        monitor.observeNotification(center, name: wake) { $0.didWake() }
        try await eventually { await gate.count == 1 }
        await gate.finish(report())
        try await eventually { monitor.estimate != nil }
        await Task.detached { center.post(name: sleep, object: nil) }.value
        try expect(monitor.estimate == nil, "Background sleep notification wasn't delivered safely")
        await Task.detached { center.post(name: wake, object: nil) }.value
        try await eventually { await gate.count == 2 }
        await gate.finish(report(seconds: nil))
        try await eventually { monitor.report.reading != nil }
        await monitor.stop()
        await Task.detached { center.post(name: wake, object: nil) }.value
        let count = await gate.count
        try expect(count == 2, "Stopped monitor responded to a notification")
    }
    func testStoppedMonitorIsReleased() async throws {
        let value = report()
        var monitor: BatteryMonitor? = BatteryMonitor(defaults: defaults(), historyURL: url(), observeSystem: false, read: { value })
        let reference = WeakMonitorReference(monitor)
        monitor?.start()
        await monitor?.stop()
        monitor = nil
        try await eventually { reference.value == nil }
    }
}

@main private enum AppTests {
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryTimeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = AppTestSuite(root: root)
        defer { suite.cleanup() }
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("native IOKit snapshot", suite.testRealNativeReader),
            ("desktop and absent battery", suite.testDesktopAndAbsentBattery),
            ("unavailable descriptors", suite.testUnavailableDescriptorIsNotDesktop),
            ("invalid numeric fields", suite.testMalformedCapacityAndBooleanRejected),
            ("time units and fallback", suite.testSourceTimeUnitsAndGlobalFallback),
            ("charging, full, contradictory state", suite.testChargingAndInconsistentPower),
            ("skip unused API calls", suite.testUnusedGlobalSignalNotQueried),
            ("real menu formatter", suite.testMenuStatesAndExpiredEstimates),
            ("coalesced power refresh", suite.testRefreshRequestsCoalesceWithoutLosingPowerChange),
            ("stop drops late read", suite.testStopDropsLateReadAndIgnoresWake),
            ("clear history/read race", suite.testClearDropsReadFromPreviousHistorySession),
            ("sleep/wake lifecycle", suite.testSleepWakeResetsEstimate),
            ("mode change/read race", suite.testPowerModeChangeDropsInFlightOldMode),
            ("startup merge/final write", suite.testStartupHistoryMergeAndCleanShutdown),
            ("write ordering/clock rollback", suite.testWriteOrderingSurvivesClockRollback),
            ("write error", suite.testWriteFailureIsReported),
            ("corrupt history", suite.testCorruptHistoryLoadsWithoutCrash),
            ("interval validation", suite.testInvalidRefreshIntervalIsNormalized),
            ("permission/off race", suite.testTurningAlertsOffWinsOverPendingPermission),
            ("permission failure", suite.testNotificationPermissionFailureIsHandled),
            ("pending read/menu freshness", suite.testPendingReadStillRefreshesMenuFreshness),
            ("power notification burst", suite.testPowerNotificationBurstIsBounded),
            ("trailing event canceled", suite.testStopCancelsTrailingPowerNotification),
            ("background power notifications", suite.testBackgroundPowerNotificationUsesMainActor),
            ("monitor released", suite.testStoppedMonitorIsReleased)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count) native app scenarios completed; \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
