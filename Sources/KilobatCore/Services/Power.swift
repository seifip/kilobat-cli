import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Battery, charger and heat: whether staying awake is wise, and what a long run cost.
public struct PowerState: Codable, Equatable, Sendable {
    public let batteryPercent: Int?
    public let onAC: Bool
    public let thermal: String
    public let lowPowerMode: Bool

    public static func read() -> PowerState {
        var percent: Int?, onAC = true
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 { percent = current * 100 / maximum }
                if let state = description[kIOPSPowerSourceStateKey] as? String { onAC = state == kIOPSACPowerValue }
            }
        }
        return PowerState(batteryPercent: percent, onAC: onAC, thermal: Self.thermal(ProcessInfo.processInfo.thermalState),
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
    }
    /// Orders thermal states so a session can keep its hottest.
    static func heat(_ thermal: String) -> Int { ["nominal": 0, "fair": 1, "serious": 2, "critical": 3][thermal] ?? 0 }
}

/// Keeps macOS from idle-sleeping while it exists. Closing the lid still sleeps the Mac; only the power helper (LidKeeper) can stop that.
public final class SleepAssertion: @unchecked Sendable {
    private var ids: [IOPMAssertionID] = []
    public init?(reason: String, display: Bool = false) {
        for type in ["PreventUserIdleSystemSleep"] + (display ? ["PreventUserIdleDisplaySleep"] : []) {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess { ids.append(id) }
        }
        if ids.isEmpty { return nil }
    }
    public func release() { ids.forEach { IOPMAssertionRelease($0) }; ids = [] }
    deinit { release() }
}
