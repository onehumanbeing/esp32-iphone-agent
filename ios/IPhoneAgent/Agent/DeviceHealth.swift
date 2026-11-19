import Foundation
import UIKit

/// Battery, Low Power Mode and heat, read so a long run can warn or wait. Thresholds are initial estimates.
struct DeviceHealth: Equatable {
    struct Snapshot: Equatable {
        var lowPower = false
        /// 0...1, or negative when iOS has no level (a simulator, or monitoring not available yet).
        var battery: Float = -1
        var plugged = true
        /// `ProcessInfo.ThermalState.rawValue`.
        var thermal = 0
        static let ok = Snapshot()
    }

    static let warnBattery: Float = 0.30
    static let pauseBattery: Float = 0.10
    static let thermalPause = 2.0

    static func shouldPause(_ s: Snapshot) -> Bool {
        !s.plugged && s.battery >= 0 && s.battery < pauseBattery
    }

    static func shouldWarn(_ s: Snapshot) -> Bool {
        !s.plugged && s.battery >= 0 && s.battery < warnBattery
    }

    static func isHot(_ s: Snapshot) -> Bool {
        s.thermal >= ProcessInfo.ThermalState.serious.rawValue
    }
}

extension AppModel {
    func healthSnapshot() -> DeviceHealth.Snapshot {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state = device.batteryState
        let plugged = state == .charging || state == .full || state == .unknown
        return DeviceHealth.Snapshot(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     battery: device.batteryLevel, plugged: plugged,
                                     thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }
}
