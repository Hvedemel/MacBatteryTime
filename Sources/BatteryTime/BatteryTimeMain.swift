import AppKit
import SwiftUI
import Combine
import UserNotifications
#if SWIFT_PACKAGE
import BatteryCore
#endif

@main
enum BatteryTimeMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnostics") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(BatteryReader.read())
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("Diagnostics failed: \(error)\n", stderr); exit(EXIT_FAILURE) }
            return
        }
        // Avoid duplicate menu items and concurrent writers when another copy is open.
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        // NSApplication.delegate is weak. Keep the delegate alive for the entire run loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let monitor = BatteryMonitor()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var dashboard: NSWindow?
    private var settings: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var lastPresentation: StatusPresentation?
    private var symbolImages: [String: NSImage] = [:]
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.imagePosition = .imageLeading
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            monitor: monitor, openDashboard: { [weak self] in self?.showDashboard() },
            openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }))
        monitor.onChange = { [weak self] in self?.updateStatusItem() }
        monitor.$showTimeInMenu.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }.store(in: &subscriptions)
        UNUserNotificationCenter.current().delegate = self
        monitor.start()
        updateStatusItem()
        if monitor.showDashboardOnLaunch && !CommandLine.arguments.contains("--background") { showDashboard() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        subscriptions.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await monitor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let presentation = StatusPresentation.make(report: monitor.report, estimate: monitor.estimate, now: Date(),
            showTime: monitor.showTimeInMenu, maximumAge: max(150, monitor.refreshInterval * 2.5))
        guard presentation != lastPresentation else { return }
        if presentation.symbol != lastPresentation?.symbol {
            if symbolImages[presentation.symbol] == nil {
                let image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: "Battery")
                image?.isTemplate = true
                symbolImages[presentation.symbol] = image
            }
            button.image = symbolImages[presentation.symbol]
        }
        button.title = presentation.title
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.toolTip)
        lastPresentation = presentation
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showDashboard() {
        popover.performClose(nil)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "BatteryTime"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 800, height: 730)
            window.contentView = NSHostingView(rootView: DashboardView(monitor: monitor, openSettings: { [weak self] in self?.showSettings() }))
            if !window.setFrameUsingName("BatteryTimeDashboard") { window.center() }
            window.setFrameAutosaveName("BatteryTimeDashboard")
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "BatteryTime Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(monitor: monitor))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Release hosting trees so closed windows cannot retain minute timelines/charts.
        if window === dashboard { window.contentView = nil; dashboard = nil }
        if window === settings { window.contentView = nil; settings = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settings { monitor.refreshSystemSettings() }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BatteryTime", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let dashboard = appMenu.addItem(withTitle: "Battery Overview", action: #selector(showDashboard), keyEquivalent: "1")
        dashboard.target = self
        let batteryMenu = appMenu.addItem(withTitle: "Show Battery Menu", action: #selector(togglePopover), keyEquivalent: "b")
        batteryMenu.target = self
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BatteryTime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
