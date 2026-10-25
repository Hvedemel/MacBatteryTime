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
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  (description[kIOPSIsPresentKey] as? Bool) != false else { continue }

            let sourceState = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool
            let power: PowerState
            if charging == true { power = .charging }
            else if sourceState == kIOPSACPowerValue { power = .pluggedIn }
            else if sourceState == kIOPSBatteryPowerValue, charging == false { power = .battery }
            else { power = .unknown }

            // Global IOPS time is in seconds; per-source Time to Empty is in minutes.
            let globalTime = BatteryReading.validSeconds(IOPSGetTimeRemainingEstimate())
            let sourceTime = number(description, kIOPSTimeToEmptyKey).flatMap { BatteryReading.validSeconds($0 * 60) }
            let registry = registryDetails()
            let health = healthText(description[kIOPSBatteryHealthKey] as? String,
                                    condition: description[kIOPSBatteryHealthConditionKey] as? String)
            let reading = BatteryReading(
                date: date, current: number(description, kIOPSCurrentCapacityKey),
                maximum: number(description, kIOPSMaxCapacityKey), power: power,
                systemSeconds: power == .battery ? (sourceTime ?? globalTime) : nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                identity: registry.identity ?? (description[kIOPSNameKey] as? String ?? "internal"),
                health: health, cycles: registry.cycles,
                fullCapacity: number(description, kIOPSNominalCapacityKey),
                designCapacity: number(description, kIOPSDesignCapacityKey)
            )
            return BatteryReport(availability: reading == nil ? .unavailable : .available, reading: reading,
                                 message: reading == nil ? "macOS did not report a valid battery capacity. Retrying automatically." : "Live IOKit reading")
        }
        return BatteryReport(availability: .noBattery, reading: nil,
                             message: "This Mac has no internal battery. BatteryTime will detect one automatically if it becomes available.")
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
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
