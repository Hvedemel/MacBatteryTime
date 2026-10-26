import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
#if SWIFT_PACKAGE
import BatteryCore
#endif

enum BatteryAvailability: String, Codable, Sendable { case available, noBattery, unavailable }

struct BatteryReport: Codable, Sendable {
    let availability: BatteryAvailability
    let reading: BatteryReading?
    let message: String
}

enum BatteryReader {
    static func read(at date: Date = Date()) -> BatteryReport {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryReport(availability: .unavailable, reading: nil, message: "macOS power information is temporarily unavailable.")
        }
        let descriptions = sources.map { source -> [String: Any]? in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }
        return decode(descriptions, at: date, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                      globalSeconds: { IOPSGetTimeRemainingEstimate() }, registry: registryDetails)
    }

    /// Separate decoding from IOKit ownership so missing/malformed hardware fields are testable.
    static func decode(_ descriptions: [[String: Any]?], at date: Date, lowPowerMode: Bool,
                       globalSeconds: () -> Double, registry: () -> (identity: String?, cycles: Int?)) -> BatteryReport {
        var incomplete = false
        for optional in descriptions {
            guard let description = optional, let type = description[kIOPSTypeKey] as? String else {
                incomplete = true
                continue
            }
            guard type == kIOPSInternalBatteryType,
                  (description[kIOPSIsPresentKey] as? Bool) != false else { continue }
            let source = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool
            let power: PowerState
            if source == kIOPSACPowerValue { power = charging == true ? .charging : .pluggedIn }
            else if source == kIOPSBatteryPowerValue, charging == false { power = .battery }
            else { power = .unknown }
            var seconds: Double?
            if power == .battery {
                // Per-source time is minutes. The global API uses seconds and may include a UPS.
                seconds = number(description, kIOPSTimeToEmptyKey).flatMap { BatteryReading.validSeconds($0 * 60) }
                if seconds == nil { seconds = BatteryReading.validSeconds(globalSeconds()) }
            }
            let metadata = registry()
            let reading = BatteryReading(date: date, current: number(description, kIOPSCurrentCapacityKey),
                maximum: number(description, kIOPSMaxCapacityKey), power: power, systemSeconds: seconds,
                lowPowerMode: lowPowerMode,
                identity: metadata.identity ?? (description[kIOPSNameKey] as? String ?? "internal"),
                health: healthText(description[kIOPSBatteryHealthKey] as? String,
                                   condition: description[kIOPSBatteryHealthConditionKey] as? String),
                cycles: metadata.cycles, fullCapacity: number(description, kIOPSNominalCapacityKey),
                designCapacity: number(description, kIOPSDesignCapacityKey))
            return BatteryReport(availability: reading == nil ? .unavailable : .available, reading: reading,
                message: reading == nil ? "macOS did not report a valid battery capacity. Retrying automatically." : "Live IOKit reading")
        }
        return BatteryReport(availability: incomplete ? .unavailable : .noBattery, reading: nil,
            message: incomplete ? "A power-source description is temporarily unavailable. Retrying automatically."
                : "This Mac has no internal battery. BatteryTime will detect one automatically if it becomes available.")
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        guard let value = dictionary[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func registryDetails() -> (identity: String?, cycles: Int?) {
        // Public IOKit registry API and documented IOPMPowerSource keys from IOPM.h.
        // No private SMC calls, shell commands, serial numbers, or driver-specific capacity guesses.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let installed = IORegistryEntryCreateCFProperty(service, kIOPMPSBatteryInstalledKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            guard installed != false else { continue }
            var entryID: UInt64 = 0
            let hasID = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
            let cycles = IORegistryEntryCreateCFProperty(service, kIOPMPSCycleCountKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            if installed == true || cycles != nil {
                return (hasID ? String(entryID) : nil, cycles?.intValue)
            }
        }
        return (nil, nil)
    }

    private static func healthText(_ health: String?, condition: String?) -> String? {
        if let condition, !condition.isEmpty { return condition }
        switch health {
        case kIOPSGoodValue: return "Normal"
        case kIOPSFairValue: return "Reduced capacity"
        case kIOPSPoorValue: return "Service recommended"
        default: return health
        }
    }
}

/// One representation is used by the real status button and the automated menu tests.
struct StatusPresentation: Equatable {
    let symbol: String
    let title: String
    let toolTip: String

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

    static func make(report: BatteryReport, estimate: BatteryEstimate?, now: Date,
                     showTime: Bool, maximumAge: TimeInterval) -> StatusPresentation {
        guard let reading = report.reading else {
            return StatusPresentation(symbol: symbol(nil), title: report.availability == .noBattery ? " No battery" : " —",
                                      toolTip: report.message)
        }
        let current = estimate.flatMap { $0.isFresh(at: now, maximumAge: maximumAge) ? $0 : nil }
        var text = " \(reading.percentage)%"
        switch reading.power {
        case .charging: text += " · Charging"
        case .pluggedIn: text += " · AC"
        case .unknown: text += " · —"
        case .battery:
            if showTime { text += current.map { " · \(TimeText.compact($0.remaining(at: now)))" } ?? " · …" }
        }
        let time = reading.power == .battery ? current.map { " · Estimated \(TimeText.full($0.remaining(at: now))) remaining" } ?? "" : ""
        return StatusPresentation(symbol: symbol(reading), title: text, toolTip: "BatteryTime · \(reading.power.title)\(time)")
    }
}
