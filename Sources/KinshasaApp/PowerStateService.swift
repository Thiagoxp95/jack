import Foundation
import IOKit.ps

enum PowerStateService {
    static func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func isOnExternalPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return true
        }

        var sawBattery = false
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey as String] as? String
            else {
                continue
            }

            if state == kIOPSACPowerValue {
                return true
            }
            if state == kIOPSBatteryPowerValue {
                sawBattery = true
            }
        }

        return !sawBattery
    }

    static func shouldRunKeepWarm(onlyWhenPluggedIn: Bool) -> Bool {
        if isLowPowerModeEnabled() {
            return false
        }

        if onlyWhenPluggedIn, !isOnExternalPower() {
            return false
        }

        return true
    }
}
