import Foundation

struct HardwareSnapshot: Sendable {
  let machineName: String
  let modelIdentifier: String
  let chipName: String
  let architecture: String
  let physicalCores: Int
  let logicalCores: Int
  let performanceCores: Int?
  let efficiencyCores: Int?
  let memoryBytes: UInt64
  let operatingSystem: String
  let uptime: TimeInterval
  let thermalState: HardwareThermalState
  let storage: HardwareStorageInfo
  let displays: [HardwareDisplayInfo]
  let usbDevices: [HardwareUSBDevice]
  let bluetooth: HardwareBluetoothInfo
  let wifi: HardwareWiFiInfo
}

enum HardwareThermalState: String, Sendable {
  case nominal
  case fair
  case serious
  case critical
  case unknown
}

struct HardwareStorageInfo: Sendable {
  let totalBytes: UInt64
  let availableBytes: UInt64
}

struct HardwareDisplayInfo: Identifiable, Sendable {
  let id: String
  let name: String
  let resolution: String
  let pixelResolution: String
  let isBuiltIn: Bool
  let isMain: Bool
}

struct HardwareUSBDevice: Identifiable, Sendable {
  let id: String
  let name: String
  let manufacturer: String
  let speed: String
  let productID: String
  let vendorID: String
}

struct HardwareBluetoothDevice: Identifiable, Sendable {
  let id: String
  let name: String
  let type: String
  let signal: Int?
}

struct HardwareBluetoothInfo: Sendable {
  let isAvailable: Bool
  let isPoweredOn: Bool
  let chipset: String
  let connectedDevices: [HardwareBluetoothDevice]
}

struct HardwareWiFiInfo: Sendable {
  let isAvailable: Bool
  let isPoweredOn: Bool
  let interfaceName: String
  let ssid: String?
  let signalDBm: Int?
  let transmitRateMbps: Double?
  let channel: Int?
}

struct BatterySnapshot: Sendable {
  let chargePercent: Double
  let healthPercent: Double?
  let cycleCount: Int
  let cycleLimit: Int?
  let isCharging: Bool
  let isExternalPowerConnected: Bool
  let isFullyCharged: Bool
  let timeRemainingMinutes: Int?
  let designCapacityMAh: Int?
  let fullChargeCapacityMAh: Int?
  let remainingCapacityMAh: Int?
  let voltageMillivolts: Int?
  let amperageMilliamps: Int?
  let systemPowerWatts: Double?
  let chargingPowerWatts: Double?
  let temperatureCelsius: Double?
  let condition: BatteryCondition
}

enum BatteryCondition: String, Sendable {
  case normal
  case serviceRecommended
  case unknown
}
