import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import UserNotifications
#if SWIFT_PACKAGE
import BatteryCore
#endif

private actor HistoryPersistence {
    let url: URL
    private var lastWrite = Date.distantPast
    init(url: URL) { self.url = url }
    func save(_ points: [HistoryPoint], at date: Date) -> String? {
        guard date >= lastWrite else { return nil }
        lastWrite = date
        do { try HistoryStore.save(points, to: url, now: date); return nil }
        catch { return "History could not be saved: \(error.localizedDescription)" }
    }
}

// This source is installed only on the main run loop. The context is valid until stop().
private func powerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.refresh() }
}

@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    @Published private(set) var report = BatteryReport(availability: .unavailable, reading: nil, message: "Reading battery information…")
    @Published private(set) var estimate: BatteryEstimate?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var storageMessage: String?
    @Published private(set) var notificationMessage = "Alerts are off."
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginMessage: String?
    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            estimator.maximumGap = max(150, refreshInterval * 2.5)
            if started && !sleeping { scheduleTimer() }
        }
    }
    @Published private(set) var alertsEnabled: Bool
    @Published var showTimeInMenu: Bool {
        didSet { UserDefaults.standard.set(showTimeInMenu, forKey: "showTimeInMenu") }
    }
    @Published var showDashboardOnLaunch: Bool {
        didSet { UserDefaults.standard.set(showDashboardOnLaunch, forKey: "showDashboardOnLaunch") }
    }
    var onChange: (() -> Void)?
    private var estimator = DischargeEstimator()
    private var alertPolicy = LowBatteryAlerts()
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var lastSaved = Date.distantPast
    private var lastHistoryPoint = Date.distantPast
    private let persistence: HistoryPersistence
    let historyURL: URL

    override init() {
        let defaults = UserDefaults.standard
        let storedInterval = defaults.double(forKey: "refreshInterval")
        refreshInterval = [15.0, 30, 60, 120].contains(storedInterval) ? storedInterval : 30
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        showTimeInMenu = defaults.object(forKey: "showTimeInMenu") as? Bool ?? true
        showDashboardOnLaunch = defaults.object(forKey: "showDashboardOnLaunch") as? Bool ?? true
        historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryTime", isDirectory: true).appendingPathComponent("history.json")
        persistence = HistoryPersistence(url: historyURL)
        super.init()
        estimator.maximumGap = max(150, refreshInterval * 2.5)
        do { history = try HistoryStore.load(from: historyURL, now: Date()) }
        catch { storageMessage = "Saved history could not be read. New readings will start a fresh history." }
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerModeChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        powerSource = IOPSNotificationCreateRunLoopSource(powerSourceDidChange, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        scheduleTimer()
        refresh()
        refreshSystemSettings()
    }

    func stop() async {
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        timer = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        // Serialize the final write after pending writes before AppKit completes termination.
        storageMessage = await persistence.save(history, at: Date())
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = min(10, refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc func refresh() {
        guard started, !sleeping, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let next = await Task.detached(priority: .utility) { BatteryReader.read() }.value
            guard let self, !Task.isCancelled, !self.sleeping else { return }
            self.apply(next)
            self.refreshTask = nil
        }
    }

    private func apply(_ next: BatteryReport) {
        report = next
        let now = next.reading?.date ?? Date()
        lastUpdated = now
        if let reading = next.reading {
            estimate = estimator.ingest(reading)
            if now.timeIntervalSince(lastHistoryPoint) >= 15 || history.last?.power != reading.power || history.last?.session != estimator.session {
                history.append(HistoryPoint(date: now, level: reading.level, power: reading.power,
                                            estimateSeconds: estimate?.seconds, session: estimator.session))
                history = HistoryStore.pruned(history, now: now)
                lastHistoryPoint = now
            }
            if let threshold = alertPolicy.evaluate(reading), alertsEnabled { sendAlert(threshold, reading: reading) }
        } else { estimator.reset(); estimate = nil }
        if now.timeIntervalSince(lastSaved) >= 60 { persist(now: now) }
        onChange?()
    }

    @objc private func willSleep() {
        sleeping = true
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        timer = nil
        estimator.reset()
        estimate = nil
        persist(now: Date())
        onChange?()
    }

    @objc private func didWake() {
        sleeping = false
        estimator.reset()
        scheduleTimer()
        refresh()
    }

    @objc private func powerModeChanged() {
        estimator.reset()
        refresh()
    }

    func clearHistory() {
        history = []
        lastHistoryPoint = .distantPast
        estimator.reset()
        estimate = nil
        persist(now: Date())
        refresh()
    }

    private func persist(now: Date) {
        lastSaved = now
        let points = history
        Task { [weak self, persistence] in
            let error = await persistence.save(points, at: now)
            self?.storageMessage = error
        }
    }

    func setAlerts(_ enabled: Bool) {
        if !enabled {
            alertsEnabled = false
            UserDefaults.standard.set(false, forKey: "alertsEnabled")
            notificationMessage = "Alerts are off."
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                alertsEnabled = granted
                UserDefaults.standard.set(granted, forKey: "alertsEnabled")
                notificationMessage = granted ? "Alerts at 20%, 10%, and 5% while on battery." : "Permission is off. Enable BatteryTime in System Settings → Notifications."
                if granted { alertPolicy = LowBatteryAlerts(); refresh() }
            } catch { notificationMessage = "Notifications unavailable: \(error.localizedDescription)" }
        }
    }

    func refreshSystemSettings() {
        loginStatus = SMAppService.mainApp.status
        if loginStatus == .requiresApproval { loginMessage = "Approve BatteryTime in Login Items to finish enabling it." }
        else if loginStatus == .notFound { loginMessage = "Move the app to Applications and try again." }
        else { loginMessage = nil }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if alertsEnabled {
                notificationMessage = settings.authorizationStatus == .authorized
                    ? "Alerts at 20%, 10%, and 5% while on battery."
                    : "Permission is off. Enable BatteryTime in System Settings → Notifications."
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshSystemSettings()
        } catch {
            loginStatus = SMAppService.mainApp.status
            loginMessage = "Could not change login setting: \(error.localizedDescription)"
        }
    }

    private func sendAlert(_ threshold: Int, reading: BatteryReading) {
        let content = UNMutableNotificationContent()
        content.title = "Battery at \(reading.percentage)%"
        content.body = estimate.map { "About \(TimeText.full($0.seconds)) remaining. Consider connecting your power adapter." }
            ?? "Consider connecting your power adapter."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "battery-\(threshold)", content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) }
            catch { notificationMessage = "Could not deliver alert: \(error.localizedDescription)" }
        }
    }
}
