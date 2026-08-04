import Combine
import CoreWLAN
import Darwin
import Foundation
import IOKit

actor HardwareInfoService {
  func snapshot() throws -> HardwareSnapshot {
    let profile = try systemProfile()
    let hardware = firstDictionary(in: profile, key: "SPHardwareDataType") ?? [:]
    let displays = displayInfo(from: profile)
    let usbDevices = usbInfo(from: profile)
    let bluetooth = bluetoothInfo(from: profile)
    let wifi = wifiInfo()
    let storage = storageInfo()

    return HardwareSnapshot(
      machineName: string(hardware["machine_name"]) ?? string(hardware["_name"]) ?? "Mac",
      modelIdentifier: string(hardware["machine_model"]) ?? Self.sysctlString("hw.model") ?? "-",
      chipName: string(hardware["chip_type"])
        ?? Self.sysctlString("machdep.cpu.brand_string") ?? "-",
      architecture: Self.sysctlString("hw.machine") ?? "-",
      physicalCores: Self.sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount,
      logicalCores: Self.sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
      performanceCores: Self.sysctlInt("hw.perflevel0.physicalcpu"),
      efficiencyCores: Self.sysctlInt("hw.perflevel1.physicalcpu"),
      memoryBytes: Self.sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      uptime: ProcessInfo.processInfo.systemUptime,
      thermalState: thermalState,
      storage: storage,
      displays: displays,
      usbDevices: usbDevices,
      bluetooth: bluetooth,
      wifi: wifi
    )
  }

  private var thermalState: HardwareThermalState {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknown
    }
  }

  private func systemProfile() throws -> [String: Any] {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = [
      "SPHardwareDataType",
      "SPDisplaysDataType",
      "SPUSBDataType",
      "SPBluetoothDataType",
      "-json",
    ]
    process.environment = [
      "LC_ALL": "en_US.UTF-8",
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(data: errorData, encoding: .utf8) ?? "system_profiler failed"
      throw HardwareInfoError.commandFailed(detail)
    }
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HardwareInfoError.invalidResponse
    }
    return value
  }

  private func displayInfo(from profile: [String: Any]) -> [HardwareDisplayInfo] {
    let adapters = profile["SPDisplaysDataType"] as? [[String: Any]] ?? []
    var displays: [HardwareDisplayInfo] = []
    for adapter in adapters {
      let items = adapter["spdisplays_ndrvs"] as? [[String: Any]] ?? []
      for (index, item) in items.enumerated() {
        let name = string(item["_name"]) ?? "Display"
        let displayID = string(item["_spdisplays_displayID"]) ?? "\(index)"
        displays.append(
          HardwareDisplayInfo(
            id: "\(displayID):\(name)",
            name: name,
            resolution: string(item["_spdisplays_resolution"])
              ?? string(item["spdisplays_resolution"]) ?? "-",
            pixelResolution: string(item["_spdisplays_pixels"])
              ?? string(item["spdisplays_pixelresolution"]) ?? "-",
            isBuiltIn: string(item["spdisplays_connection_type"]) == "spdisplays_internal",
            isMain: string(item["spdisplays_main"]) == "spdisplays_yes"
          )
        )
      }
    }
    return displays
  }

  private func usbInfo(from profile: [String: Any]) -> [HardwareUSBDevice] {
    var records: [HardwareUSBDevice] = []
    var nextID = 0

    func visit(_ value: Any, includeCurrent: Bool) {
      if let values = value as? [Any] {
        values.forEach { visit($0, includeCurrent: includeCurrent) }
        return
      }
      guard let dictionary = value as? [String: Any] else { return }
      if includeCurrent, let name = string(dictionary["_name"]), !name.isEmpty {
        nextID += 1
        records.append(
          HardwareUSBDevice(
            id: "usb-\(nextID)-\(name)",
            name: name,
            manufacturer: string(dictionary["manufacturer"]) ?? "-",
            speed: string(dictionary["device_speed"])
              ?? string(dictionary["speed"]) ?? "-",
            productID: string(dictionary["product_id"]) ?? "-",
            vendorID: string(dictionary["vendor_id"]) ?? "-"
          )
        )
      }
      if let children = dictionary["_items"] {
        visit(children, includeCurrent: true)
      }
    }

    if let usbRoot = profile["SPUSBDataType"] {
      visit(usbRoot, includeCurrent: true)
    }
    return records
  }

  private func bluetoothInfo(from profile: [String: Any]) -> HardwareBluetoothInfo {
    guard
      let root = firstDictionary(in: profile, key: "SPBluetoothDataType"),
      let controller = root["controller_properties"] as? [String: Any]
    else {
      return HardwareBluetoothInfo(
        isAvailable: false,
        isPoweredOn: false,
        chipset: "-",
        connectedDevices: []
      )
    }

    let connected = root["device_connected"] as? [[String: Any]] ?? []
    let devices = connected.flatMap { item -> [HardwareBluetoothDevice] in
      item.compactMap { name, value in
        guard let details = value as? [String: Any] else { return nil }
        return HardwareBluetoothDevice(
          id: "bluetooth:\(name)",
          name: name,
          type: string(details["device_minorType"]) ?? "-",
          signal: Int(string(details["device_rssi"]) ?? "")
        )
      }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    return HardwareBluetoothInfo(
      isAvailable: true,
      isPoweredOn: string(controller["controller_state"]) == "attrib_on",
      chipset: string(controller["controller_chipset"]) ?? "-",
      connectedDevices: devices
    )
  }

  private func wifiInfo() -> HardwareWiFiInfo {
    let client = CWWiFiClient.shared()
    guard let interface = client.interface() else {
      return HardwareWiFiInfo(
        isAvailable: false,
        isPoweredOn: false,
        interfaceName: "-",
        ssid: nil,
        signalDBm: nil,
        transmitRateMbps: nil,
        channel: nil
      )
    }
    let signal = interface.rssiValue()
    let rate = interface.transmitRate()
    return HardwareWiFiInfo(
      isAvailable: true,
      isPoweredOn: interface.powerOn(),
      interfaceName: interface.interfaceName ?? "-",
      ssid: interface.ssid(),
      signalDBm: signal == 0 ? nil : signal,
      transmitRateMbps: rate > 0 ? rate : nil,
      channel: interface.wlanChannel()?.channelNumber
    )
  }

  private func storageInfo() -> HardwareStorageInfo {
    let keys: Set<URLResourceKey> = [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
    ]
    let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
    return HardwareStorageInfo(
      totalBytes: UInt64(max(0, values?.volumeTotalCapacity ?? 0)),
      availableBytes: UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
    )
  }

  private func firstDictionary(in profile: [String: Any], key: String) -> [String: Any]? {
    (profile[key] as? [[String: Any]])?.first
  }

  private func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func sysctlInt(_ name: String) -> Int? {
    var value = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }

  private static func sysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }
}

actor BatteryInfoService {
  func snapshot() -> BatterySnapshot? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("AppleSmartBattery")
    )
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var unmanagedProperties: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(
        service,
        &unmanagedProperties,
        kCFAllocatorDefault,
        0
      ) == KERN_SUCCESS,
      let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any]
    else {
      return nil
    }

    let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
    let current = number(properties["CurrentCapacity"]) ?? number(batteryData["CurrentCapacity"]) ?? 0
    let maximum = max(1, number(properties["MaxCapacity"]) ?? number(batteryData["MaxCapacity"]) ?? 100)
    let designCapacity = number(batteryData["DesignCapacity"])
    let fullChargeCapacity = number(batteryData["FullChargeCapacity"])
    let voltage = number(properties["Voltage"])
    let amperage = number(properties["InstantAmperage"]) ?? number(properties["Amperage"])
    let powerUsage = PowerMetricsReader.read(batteryProperties: properties)

    let healthPercent: Double?
    if let designCapacity, designCapacity > 0, let fullChargeCapacity {
      healthPercent = min(150, max(0, Double(fullChargeCapacity) / Double(designCapacity) * 100))
    } else {
      healthPercent = nil
    }

    let temperature = batteryTemperature(number(properties["Temperature"]))
    let failureStatus = number(properties["PermanentFailureStatus"]) ?? 0
    let healthText = (properties["BatteryHealth"] as? String)?.lowercased() ?? ""
    let condition: BatteryCondition
    if failureStatus != 0 || healthText.contains("service") || healthText.contains("replace") {
      condition = .serviceRecommended
    } else if healthText.isEmpty || healthText.contains("good") || healthText.contains("normal") {
      condition = .normal
    } else {
      condition = .unknown
    }

    return BatterySnapshot(
      chargePercent: min(100, max(0, Double(current) / Double(maximum) * 100)),
      healthPercent: healthPercent,
      cycleCount: number(properties["CycleCount"]) ?? 0,
      cycleLimit: number(properties["DesignCycleCount9C"]),
      isCharging: bool(properties["IsCharging"]),
      isExternalPowerConnected: bool(properties["ExternalConnected"]),
      isFullyCharged: bool(properties["FullyCharged"]),
      timeRemainingMinutes: validMinutes(number(properties["TimeRemaining"])),
      designCapacityMAh: designCapacity,
      fullChargeCapacityMAh: fullChargeCapacity,
      remainingCapacityMAh: number(batteryData["RemainingCapacity"]),
      voltageMillivolts: voltage,
      amperageMilliamps: amperage,
      systemPowerWatts: powerUsage.systemWatts,
      chargingPowerWatts: powerUsage.chargingWatts,
      temperatureCelsius: temperature,
      condition: condition
    )
  }

  private func number(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private func bool(_ value: Any?) -> Bool {
    (value as? NSNumber)?.boolValue ?? false
  }

  private func validMinutes(_ value: Int?) -> Int? {
    guard let value, value > 0, value < 65_535 else { return nil }
    return value
  }

  private func batteryTemperature(_ rawValue: Int?) -> Double? {
    guard let rawValue else { return nil }
    if rawValue > 1_000 {
      let celsius = Double(rawValue) / 10 - 273.15
      return (-20...100).contains(celsius) ? celsius : nil
    }
    let celsius = Double(rawValue) / 100
    return (-20...100).contains(celsius) ? celsius : nil
  }
}

@MainActor
final class HardwareInfoStore: ObservableObject {
  @Published private(set) var snapshot: HardwareSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage = ""

  private let service = HardwareInfoService()
  private var task: Task<Void, Never>?

  func refresh() {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = ""
    task?.cancel()
    task = Task { [weak self, service] in
      do {
        let snapshot = try await service.snapshot()
        guard !Task.isCancelled else { return }
        self?.snapshot = snapshot
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isLoading = false
    }
  }
}

@MainActor
final class BatteryInfoStore: ObservableObject {
  @Published private(set) var snapshot: BatterySnapshot?
  @Published private(set) var hasLoaded = false
  @Published private(set) var isLoading = false

  private let service = BatteryInfoService()
  private var monitoringTask: Task<Void, Never>?

  func startMonitoring() {
    guard monitoringTask == nil else { return }
    refresh()
    monitoringTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard !Task.isCancelled else { return }
        self?.refresh()
      }
    }
  }

  func stopMonitoring() {
    monitoringTask?.cancel()
    monitoringTask = nil
  }

  func refresh() {
    guard !isLoading else { return }
    isLoading = true
    Task { [weak self, service] in
      let snapshot = await service.snapshot()
      guard !Task.isCancelled else { return }
      self?.snapshot = snapshot
      self?.hasLoaded = true
      self?.isLoading = false
    }
  }
}

private enum HardwareInfoError: LocalizedError {
  case commandFailed(String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .commandFailed(let detail): detail
    case .invalidResponse: "The hardware information response could not be read."
    }
  }
}
