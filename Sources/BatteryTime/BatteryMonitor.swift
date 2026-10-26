import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import UserNotifications
#if SWIFT_PACKAGE
import BatteryCore
#endif

actor HistoryPersistence {
    let url: URL
    private var latestRevision: UInt64 = 0
    init(url: URL) { self.url = url }
    func load(now: Date) -> (points: [HistoryPoint], error: String?) {
        do { return (try HistoryStore.load(from: url, now: now), nil) }
        catch { return ([], "Saved history could not be read. New readings will start a fresh history.") }
    }
    func save(_ points: [HistoryPoint], revision: UInt64, now: Date) -> String? {
        // Ordering cannot depend on wall time: the clock can move backwards while running.
        guard revision >= latestRevision else { return nil }
        latestRevision = revision
        do { try HistoryStore.save(points, to: url, now: now); return nil }
        catch { return "History could not be saved: \(error.localizedDescription)" }
    }
}

// This source is installed only on the main run loop. The context is valid until stop().
private func powerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.powerSourceChanged() }
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
            if ![15.0, 30, 60, 120].contains(refreshInterval) { refreshInterval = 30 }
            defaults.set(refreshInterval, forKey: "refreshInterval")
            estimator.maximumGap = max(150, refreshInterval * 2.5)
            if started && !sleeping { scheduleTimer() }
        }
    }
    @Published private(set) var alertsEnabled: Bool
    @Published var showTimeInMenu: Bool {
        didSet { defaults.set(showTimeInMenu, forKey: "showTimeInMenu") }
    }
    @Published var showDashboardOnLaunch: Bool {
        didSet { defaults.set(showDashboardOnLaunch, forKey: "showDashboardOnLaunch") }
    }
    var onChange: (() -> Void)?
    private var estimator = DischargeEstimator()
    private var alertPolicy = LowBatteryAlerts()
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var lastSavedUptime = -Double.infinity
    private var writeRevision: UInt64 = 0
    private var readGeneration: UInt64 = 0
    private var refreshPending = false
    private var notificationTask: Task<Void, Never>?
    private var lastNotificationRead = -Double.infinity
    private let notificationInterval: TimeInterval
    private var historyEpoch: UInt64 = 0
    private var historyLoaded = false
    private var historyDirty = false
    private var loadTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var alertRequestRevision: UInt64 = 0
    private let defaults: UserDefaults
    private let observeSystem: Bool
    private let read: @Sendable () async -> BatteryReport
    private let uptime: @Sendable () -> TimeInterval
    private let requestAlertPermission: @Sendable () async throws -> Bool
    private var lastHistoryPoint = Date.distantPast
    private let persistence: HistoryPersistence
    let historyURL: URL

    init(defaults: UserDefaults = .standard, historyURL: URL? = nil, observeSystem: Bool = true,
         read: @escaping @Sendable () async -> BatteryReport = {
             await Task.detached(priority: .utility) { BatteryReader.read() }.value
         }, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         notificationInterval: TimeInterval = 2,
         requestAlertPermission: @escaping @Sendable () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         }) {
        self.defaults = defaults
        self.observeSystem = observeSystem
        self.read = read
        self.uptime = uptime
        self.notificationInterval = notificationInterval.isFinite ? min(2, max(0.01, notificationInterval)) : 2
        self.requestAlertPermission = requestAlertPermission
        let storedInterval = defaults.double(forKey: "refreshInterval")
        refreshInterval = [15.0, 30, 60, 120].contains(storedInterval) ? storedInterval : 30
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        showTimeInMenu = defaults.object(forKey: "showTimeInMenu") as? Bool ?? true
        showDashboardOnLaunch = defaults.object(forKey: "showDashboardOnLaunch") as? Bool ?? true
        self.historyURL = historyURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryTime", isDirectory: true).appendingPathComponent("history.json")
        persistence = HistoryPersistence(url: self.historyURL)
        super.init()
        estimator.maximumGap = max(150, refreshInterval * 2.5)

    }

    func start() {
        guard !started else { return }
        started = true
        sleeping = false
        if observeSystem {
            let workspace = NSWorkspace.shared.notificationCenter
            observeNotification(workspace, name: NSWorkspace.willSleepNotification) { $0.willSleep() }
            observeNotification(workspace, name: NSWorkspace.didWakeNotification) { $0.didWake() }
            observeNotification(.default, name: .NSProcessInfoPowerStateDidChange) { $0.powerModeChanged() }
            powerSource = IOPSNotificationCreateRunLoopSource(powerSourceDidChange, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
            if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        }
        let epoch = historyEpoch
        loadTask = Task { [weak self, persistence] in
            let loaded = await persistence.load(now: Date())
            guard let self else { return }
            if self.historyEpoch == epoch {
                self.history = HistoryStore.pruned(loaded.points + self.history, now: Date())
                self.storageMessage = loaded.error
            }
            self.historyLoaded = true
            self.loadTask = nil
            self.persist(now: Date())
        }
        scheduleTimer()
        refresh()
        if observeSystem { refreshSystemSettings() }
    }

    func stop() async {
        started = false
        cancelRefresh()
        timer?.invalidate()
        timer = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        for (center, token) in notificationObservers { center.removeObserver(token) }
        notificationObservers.removeAll()
        settingsTask?.cancel()
        settingsTask = nil
        alertRequestRevision &+= 1
        await loadTask?.value
        writeRevision &+= 1
        // Serialize the final write after pending writes before AppKit completes termination.
        storageMessage = await persistence.save(history, revision: writeRevision, now: Date())
    }

    func observeNotification(_ center: NotificationCenter, name: Notification.Name,
                             action: @escaping @MainActor @Sendable (BatteryMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // NotificationCenter can be posted from any thread; the explicit main queue
            // makes this actor hop valid on every supported macOS version.
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        notificationObservers.append((center, token))
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = min(10, refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelRefresh() {
        readGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        notificationTask?.cancel()
        notificationTask = nil
        lastNotificationRead = -Double.infinity
    }

    /// Refresh the first power event immediately, then coalesce a chatter burst into
    /// one trailing read. This isn't a second continuously running polling timer.
    func powerSourceChanged() {
        guard started, !sleeping else { return }
        let elapsed = uptime() - lastNotificationRead
        if elapsed >= notificationInterval {
            notificationTask?.cancel()
            notificationTask = nil
            lastNotificationRead = uptime()
            refresh()
            return
        }
        guard notificationTask == nil else { return }
        let generation = readGeneration
        let delay = notificationInterval - max(0, elapsed)
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.started, !self.sleeping, generation == self.readGeneration else { return }
            self.notificationTask = nil
            self.lastNotificationRead = self.uptime()
            self.refresh()
        }
    }

    @objc func refresh() {
        guard started, !sleeping else { return }
        onChange?() // Expire a menu estimate even if a slow native read hasn't completed.
        guard refreshTask == nil else { refreshPending = true; return }
        let generation = readGeneration
        let read = read
        refreshTask = Task { [weak self] in
            let next = await read()
            guard let self, !Task.isCancelled, self.started, !self.sleeping,
                  self.readGeneration == generation else { return }
            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
                return
            }
            self.apply(next)
        }
    }

    private func apply(_ next: BatteryReport) {
        report = next
        let now = next.reading?.date ?? Date()
        lastUpdated = now
        if let reading = next.reading {
            estimate = estimator.ingest(reading)
            if now.timeIntervalSince(lastHistoryPoint) >= 15 || history.last?.power != reading.power || history.last?.session != estimator.session {
                let point = HistoryPoint(date: now, level: reading.level, power: reading.power,
                                         estimateSeconds: estimate?.seconds, session: estimator.session)
                history = HistoryStore.appending(point, to: history, now: now)
                historyDirty = true
                lastHistoryPoint = now
            }
            if let threshold = alertPolicy.evaluate(reading), alertsEnabled { sendAlert(threshold, reading: reading) }
        } else { estimator.reset(); estimate = nil }
        if uptime() - lastSavedUptime >= 60 { persist(now: now) }
        onChange?()
    }

    func willSleep() {
        guard started else { return }
        sleeping = true
        cancelRefresh()
        timer?.invalidate()
        timer = nil
        estimator.reset()
        estimate = nil
        persist(now: Date())
        onChange?()
    }

    func didWake() {
        guard started else { return }
        sleeping = false
        estimator.reset()
        scheduleTimer()
        refresh()
    }

    func powerModeChanged() {
        guard started else { return }
        cancelRefresh()
        estimator.reset()
        estimate = nil
        onChange?()
        refresh()
    }

    func clearHistory() {
        historyEpoch &+= 1
        cancelRefresh()
        history = []
        historyDirty = true
        lastHistoryPoint = .distantPast
        estimator.reset()
        estimate = nil
        persist(now: Date())
        refresh()
    }

    private func persist(now: Date) {
        guard historyLoaded, historyDirty else { return }
        lastSavedUptime = uptime()
        historyDirty = false
        writeRevision &+= 1
        let revision = writeRevision
        let points = history
        Task { [weak self, persistence] in
            let error = await persistence.save(points, revision: revision, now: now)
            guard let self, self.writeRevision == revision else { return }
            self.storageMessage = error
            if error != nil { self.historyDirty = true }
        }
    }

    func setAlerts(_ enabled: Bool) {
        alertRequestRevision &+= 1
        let revision = alertRequestRevision
        if !enabled {
            alertsEnabled = false
            defaults.set(false, forKey: "alertsEnabled")
            notificationMessage = "Alerts are off."
            if observeSystem { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
            return
        }
        Task {
            do {
                let granted = try await requestAlertPermission()
                guard revision == alertRequestRevision else { return }
                alertsEnabled = granted
                defaults.set(granted, forKey: "alertsEnabled")
                notificationMessage = granted ? "Alerts at 20%, 10%, and 5% while on battery." : "Permission is off. Enable BatteryTime in System Settings → Notifications."
                if granted { alertPolicy = LowBatteryAlerts(); refresh() }
            } catch {
                guard revision == alertRequestRevision else { return }
                notificationMessage = "Notifications unavailable: \(error.localizedDescription)"
            }
        }
    }

    func refreshSystemSettings() {
        loginStatus = SMAppService.mainApp.status
        if loginStatus == .requiresApproval { loginMessage = "Approve BatteryTime in Login Items to finish enabling it." }
        else if loginStatus == .notFound { loginMessage = "Move the app to Applications and try again." }
        else { loginMessage = nil }
        guard alertsEnabled, settingsTask == nil else { return }
        settingsTask = Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            defer { settingsTask = nil }
            guard !Task.isCancelled else { return }
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
        guard observeSystem else { return }
        let content = UNMutableNotificationContent()
        content.title = "Battery at \(reading.percentage)%"
        content.body = estimate.map { "About \(TimeText.full($0.seconds)) remaining. Consider connecting your power adapter." }
            ?? "Consider connecting your power adapter."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "battery-\(threshold)", content: content, trigger: nil)
        let revision = alertRequestRevision
        Task {
            guard alertsEnabled, revision == alertRequestRevision else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
                if !alertsEnabled || revision != alertRequestRevision {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
                }
            } catch {
                if revision == alertRequestRevision { notificationMessage = "Could not deliver alert: \(error.localizedDescription)" }
            }
        }
    }
}
