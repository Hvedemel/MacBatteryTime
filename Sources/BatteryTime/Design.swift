import SwiftUI
#if SWIFT_PACKAGE
import BatteryCore
#endif

// Explicit type alias keeps the macOS 13 property wrapper unambiguous on newer SDKs
// that also export an unrelated @State macro requiring Xcode-only macro plugins.
typealias ViewState<Value> = SwiftUI.State<Value>

struct AnimatedPercentage: View {
    var value: Double
    @ViewBuilder var body: some View {
        if #available(macOS 14.0, *) {
            Text("\(Int(value.rounded()))").monospacedDigit().contentTransition(.numericText(value: value))
        } else {
            Text("\(Int(value.rounded()))").monospacedDigit().id(Int(value.rounded())).transition(.opacity)
        }
    }
}

enum BatteryStyle {
    static func color(_ level: Double) -> Color {
        level <= 10 ? Color(red: 0.90, green: 0.25, blue: 0.28) :
            level <= 20 ? Color(red: 0.92, green: 0.61, blue: 0.13) :
            Color(red: 0.19, green: 0.70, blue: 0.43)
    }
    static func symbol(_ reading: BatteryReading?) -> String {
        guard let reading else { return "battery.0percent" }
        if reading.power == .charging { return "battery.100percent.bolt" }
        switch reading.percentage {
        case 88...100: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.06 : 0.025), radius: 18, y: 6)
    }
}

struct BatteryGraphic: View {
    let level: Double
    let charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - 9
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(BatteryStyle.color(level).opacity(0.10))
                    .frame(width: width)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [BatteryStyle.color(level).opacity(0.75), BatteryStyle.color(level)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: max(0, (width - 10) * level / 100), height: proxy.size.height - 10)
                    .padding(5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(BatteryStyle.color(level).opacity(0.35))
                    .frame(width: 5, height: proxy.size.height * 0.36)
                    .offset(x: width + 4)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white).frame(width: width)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: level)
        .accessibilityLabel("Battery \(Int(level.rounded())) percent\(charging ? ", charging" : "")")
    }
}

struct StatusPill: View {
    let reading: BatteryReading
    var body: some View {
        Label(reading.power.title, systemImage: reading.power == .charging ? "bolt.fill" : reading.power == .pluggedIn ? "powerplug.fill" : "leaf.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(reading.power == .battery ? BatteryStyle.color(reading.level) : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.primary.opacity(0.045), in: Capsule())
    }
}

struct RemainingTimeView: View {
    @ObservedObject var monitor: BatteryMonitor
    var compact = false

    var body: some View {
        // A minute timeline runs only while a view is visible. Sampling has its own tolerant timer.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let reading = monitor.report.reading
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                Text(title(reading)).font(.system(size: compact ? 11 : 12, weight: .medium)).foregroundStyle(.secondary)
                if let estimate = monitor.estimate, reading?.power == .battery,
                   let updated = monitor.lastUpdated, context.date.timeIntervalSince(updated) <= max(150, monitor.refreshInterval * 2.5) {
                    Text(TimeText.compact(estimate.remaining(at: context.date)))
                        .font(.system(size: compact ? 32 : 52, weight: .medium, design: .rounded))
                        .tracking(compact ? -1 : -2).monospacedDigit()
                        .accessibilityLabel("Estimated \(TimeText.full(estimate.remaining(at: context.date))) remaining")
                    Text("Until about \(estimate.emptyDate.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: compact ? 11 : 13)).foregroundStyle(.secondary)
                    if !compact {
                        Label(estimate.source.title, systemImage: "waveform.path")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 8)
                    }
                } else {
                    Text(placeholder(reading))
                        .font(.system(size: compact ? 25 : 31, weight: .medium, design: .rounded)).tracking(-0.8)
                    Text(explanation(reading))
                        .font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func title(_ reading: BatteryReading?) -> String {
        reading?.power == .battery ? "ESTIMATED TIME REMAINING" : "POWER STATUS"
    }
    private func placeholder(_ reading: BatteryReading?) -> String {
        guard let reading else { return "—" }
        switch reading.power {
        case .battery: return "Calculating…"
        case .charging: return "Charging"
        case .pluggedIn: return reading.percentage >= 100 ? "Fully charged" : "Plugged in"
        case .unknown: return "Unavailable"
        }
    }
    private func explanation(_ reading: BatteryReading?) -> String {
        guard let reading else { return monitor.report.message }
        switch reading.power {
        case .battery: return "Learning from your battery use. Estimates adapt as your workload changes."
        case .charging: return "Your battery is receiving power."
        case .pluggedIn: return "Connected to external power. Charging may be paused or managed by macOS."
        case .unknown: return "Waiting for macOS to report the current power source."
        }
    }
}
