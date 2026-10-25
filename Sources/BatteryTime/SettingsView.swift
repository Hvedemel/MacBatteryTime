import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ViewState private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { monitor.loginStatus == .enabled || monitor.loginStatus == .requiresApproval }, set: monitor.setLaunchAtLogin))
                if let message = monitor.loginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    if monitor.loginStatus == .requiresApproval {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Show dashboard when BatteryTime opens", isOn: $monitor.showDashboardOnLaunch)
                Toggle("Show time remaining in menu bar", isOn: $monitor.showTimeInMenu)
            } header: { Text("General") }
            Section {
                Picker("Refresh interval", selection: $monitor.refreshInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds · recommended").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
                Text("Power changes refresh immediately. Monitoring pauses during sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Monitoring") }
            Section {
                Toggle("Low battery notifications", isOn: Binding(get: { monitor.alertsEnabled }, set: monitor.setAlerts))
                Text(monitor.notificationMessage).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Notifications") }
            Section {
                LabeledContent("History", value: "Last 24 hours · stored on this Mac")
                Button("Clear battery history…", role: .destructive) { confirmClear = true }
                Text("BatteryTime reads power information. It never changes charging, energy settings, or Low Power Mode.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy") }
            Section {
                LabeledContent("BatteryTime", value: "4.0")
                Text("Remaining time is an estimate, not a guarantee. Activity, temperature, and battery condition affect runtime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 500, height: 640)
        .onAppear { monitor.refreshSystemSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in monitor.refreshSystemSettings() }
        .confirmationDialog("Clear recorded battery history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { monitor.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the history stored on this Mac and starts a new learning session.") }
    }
}
