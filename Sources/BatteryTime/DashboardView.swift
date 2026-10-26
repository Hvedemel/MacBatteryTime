import SwiftUI
import Charts
#if SWIFT_PACKAGE
import BatteryCore
#endif

struct DashboardView: View {
    @ObservedObject var monitor: BatteryMonitor
    var openSettings: () -> Void
    @ViewState private var range: Double = 6
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Battery overview").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                        Text("A little clarity. A little more time.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: { monitor.refresh() }) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Refresh battery information").accessibilityLabel("Refresh battery information")
                    Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }
                if let reading = monitor.report.reading {
                    Card {
                        HStack(spacing: 36) {
                            VStack(alignment: .leading, spacing: 14) {
                                StatusPill(reading: reading)
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    AnimatedPercentage(value: reading.level).font(.system(size: 84, weight: .medium, design: .rounded)).tracking(-5)
                                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: reading.level)
                                    Text("%").font(.system(size: 35, weight: .regular, design: .rounded)).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                                BatteryGraphic(level: reading.level, charging: reading.power == .charging).frame(width: 144, height: 56)
                            }
                            .frame(width: 240, alignment: .leading)
                            Rectangle().fill(.primary.opacity(0.07)).frame(width: 1, height: 160)
                            RemainingTimeView(monitor: monitor).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(6)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        metric("Battery health", value: reading.capacityHealth.map { "\($0)%" } ?? reading.health ?? "Unavailable",
                               note: reading.capacityHealth != nil ? (reading.health ?? "Of design capacity") : reading.health == nil ? "Not reported by this Mac" : "Reported by macOS", symbol: "heart")
                        metric("Cycle count", value: reading.cycles.map(String.init) ?? "Unavailable",
                               note: reading.cycles == nil ? "Not reported by this Mac" : "Lifetime charge cycles", symbol: "arrow.triangle.2.circlepath")
                        metric("Low Power Mode", value: reading.lowPowerMode ? "On" : "Off",
                               note: reading.lowPowerMode ? "Using less energy" : "Standard energy use", symbol: "leaf")
                    }
                } else {
                    Card {
                        HStack(spacing: 24) {
                            Image(systemName: monitor.report.availability == .noBattery ? "desktopcomputer" : "battery.0percent")
                                .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(monitor.report.availability == .noBattery ? "No internal battery" : "Battery information unavailable")
                                    .font(.title2.weight(.semibold))
                                Text(monitor.report.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.vertical, 36)
                    }
                }
                HStack {
                    Text("Your battery, over time").font(.system(size: 18, weight: .semibold)).tracking(-0.3)
                    Spacer()
                    Picker("History range", selection: $range) {
                        Text("1 hour").tag(1.0)
                        Text("6 hours").tag(6.0)
                        Text("24 hours").tag(24.0)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 248)
                }.padding(.top, 2)
                HStack(alignment: .top, spacing: 16) {
                    HistoryChart(monitor: monitor, hours: range, kind: .level)
                    HistoryChart(monitor: monitor, hours: range, kind: .remaining)
                }
                if let reading = monitor.report.reading, let full = reading.fullCapacity, let design = reading.designCapacity {
                    HStack {
                        Label("Capacity", systemImage: "battery.100percent").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(full)) / \(Int(design)) reported capacity units").monospacedDigit()
                    }.font(.system(size: 12)).padding(.horizontal, 4)
                }
                HStack(alignment: .top) {
                    Label("Private by design. History stays on this Mac.", systemImage: "lock.shield")
                    Spacer()
                    if let date = monitor.lastUpdated { Text("Updated \(date.formatted(date: .omitted, time: .shortened)) · Every \(Int(monitor.refreshInterval))s") }
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
                if let message = monitor.storageMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            .padding(30)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.963, green: 0.969, blue: 0.971))
        .frame(minWidth: 800, minHeight: 700)
    }

    private func metric(_ title: String, value: String, note: String, symbol: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

private enum HistoryKind { case level, remaining }

private struct HistoryChart: View {
    @ObservedObject var monitor: BatteryMonitor
    let hours: Double
    let kind: HistoryKind
    @ViewState private var selectedDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = Date()
            let start = now.addingTimeInterval(-hours * 3600)
            let points = monitor.history.filter { $0.date >= start && (kind == .level || $0.estimateSeconds != nil) }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(kind == .level ? "Battery level" : "Time remaining").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(kind == .level ? "RECORDED" : "ESTIMATED").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                    }
                    if points.count >= 2 {
                        Chart(HistoryStore.chartPoints(points, remaining: kind == .remaining)) { point in
                            if let value = value(point) {
                                LineMark(x: .value("Time", point.date), y: .value("Value", value), series: .value("Session", point.session.uuidString))
                                    .foregroundStyle(kind == .level ? Color.green : Color.accentColor)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                PointMark(x: .value("Time", point.date), y: .value("Value", value))
                                    .foregroundStyle(kind == .level ? Color.green : Color.accentColor).symbolSize(5)
                            }
                        }
                        .chartXScale(domain: start...now)
                        .chartYScale(domain: 0...(kind == .level ? 100 : max(1, points.compactMap { $0.estimateSeconds.map { $0 / 3600 } }.max() ?? 1) * 1.15))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { axis in
                            AxisGridLine().foregroundStyle(.primary.opacity(0.04))
                            AxisValueLabel { if let value = axis.as(Double.self) { Text(kind == .level ? "\(Int(value))%" : "\(value, specifier: "%.0f")h").font(.system(size: 9)) } }
                        } }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                                            selectedDate = proxy.value(atX: x)
                                        case .ended: selectedDate = nil
                                        }
                                    }
                            }
                        }
                        .accessibilityLabel(kind == .level ? "Recorded battery level history" : "Recorded estimated remaining battery hours")
                        .frame(height: 116)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: kind == .level ? "chart.xyaxis.line" : "clock").font(.system(size: 23, weight: .light)).foregroundStyle(.tertiary)
                            Text(kind == .level ? "History starts here" : "Estimates will appear here").font(.system(size: 12, weight: .medium))
                            Text(kind == .level ? "Keep BatteryTime running to see your usage." : "Available while discharging, once a time estimate is ready.")
                                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).frame(height: 116)
                    }
                    Text(hoverText(points) ?? (kind == .level ? "Gaps mark sleep or a new power session." : "An estimate, adapting to your activity."))
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func value(_ point: HistoryPoint) -> Double? { kind == .level ? point.level : point.estimateSeconds.map { $0 / 3600 } }
    private func hoverText(_ points: [HistoryPoint]) -> String? {
        guard let selectedDate, let point = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) else { return nil }
        let text = kind == .level ? "\(Int(point.level.rounded()))%" : point.estimateSeconds.map(TimeText.compact) ?? "—"
        return "\(point.date.formatted(date: .omitted, time: .shortened)) · \(text)"
    }
}
