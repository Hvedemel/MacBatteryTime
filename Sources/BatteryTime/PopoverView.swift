import SwiftUI
#if SWIFT_PACKAGE
import BatteryCore
#endif

struct PopoverView: View {
    @ObservedObject var monitor: BatteryMonitor
    var openDashboard: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("BatteryTime").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            if let reading = monitor.report.reading {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(reading.percentage)%").font(.system(size: 45, weight: .medium, design: .rounded)).tracking(-2).monospacedDigit()
                        StatusPill(reading: reading)
                    }
                    Spacer()
                    BatteryGraphic(level: reading.level, charging: reading.power == .charging).frame(width: 112, height: 48)
                }
                Divider().opacity(0.5)
                RemainingTimeView(monitor: monitor, compact: true)
            } else {
                Label(monitor.report.availability == .noBattery ? "No internal battery" : "Waiting for battery", systemImage: "desktopcomputer")
                    .font(.system(size: 20, weight: .medium))
                Text(monitor.report.message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button(action: openDashboard) {
                HStack { Text("Open dashboard"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 12, weight: .medium)).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            HStack {
                Button("Refresh", action: { monitor.refresh() }).keyboardShortcut("r")
                Spacer()
                Button("Quit BatteryTime", action: quit).keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 344)
        .background(.regularMaterial)
    }
}
