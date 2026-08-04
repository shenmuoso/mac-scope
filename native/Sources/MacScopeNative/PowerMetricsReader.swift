import Foundation
import IOKit

enum PowerMetricsReader {
  static func read(batteryProperties suppliedBatteryProperties: [String: Any]? = nil) -> PowerUsage {
    let batteryProperties = suppliedBatteryProperties ?? properties(for: "AppleSmartBattery") ?? [:]
    let managerProperties = properties(for: "AppleSmartBatteryManager") ?? [:]
    return parse(
      managerProperties: managerProperties,
      batteryProperties: batteryProperties
    )
  }

  static func parse(
    managerProperties: [String: Any],
    batteryProperties: [String: Any]
  ) -> PowerUsage {
    let batteryTelemetry = dictionary(batteryProperties["PowerTelemetryData"])
    let managerTelemetry = dictionary(managerProperties["PowerTelemetryData"])
    let telemetry = batteryTelemetry.isEmpty ? managerTelemetry : batteryTelemetry
    let managerBatteryData = dictionary(managerProperties["BatteryData"])
    let batteryData = dictionary(batteryProperties["BatteryData"])
    let chargerData = dictionary(batteryProperties["ChargerData"])

    let hasBattery = bool(batteryProperties["BatteryInstalled"])
      ?? bool(batteryProperties["built-in"])
      ?? !batteryProperties.isEmpty
    let externalPower = bool(batteryProperties["ExternalConnected"])
      ?? bool(batteryProperties["AppleRawExternalConnected"])
    let isCharging = bool(batteryProperties["IsCharging"])
      ?? bool(chargerData["IsCharging"])
      ?? false

    let batteryPowerMilliwatts = plausiblePower(number(telemetry["BatteryPower"]))
      ?? plausiblePower(number(batteryData["BatteryPower"]))
      ?? plausiblePower(number(managerBatteryData["BatteryPower"]))
      ?? plausiblePower(calculatedBatteryPower(from: batteryProperties))
    let systemLoadMilliwatts = nonnegative(
      plausiblePower(number(telemetry["SystemLoad"]))
    )
    let adapterInputMilliwatts = nonnegative(
      plausiblePower(number(telemetry["SystemPowerIn"]))
    )

    let systemPowerMilliwatts: Double?
    if let systemLoadMilliwatts {
      systemPowerMilliwatts = systemLoadMilliwatts
    } else if externalPower == false, let batteryPowerMilliwatts {
      systemPowerMilliwatts = abs(batteryPowerMilliwatts)
    } else if let adapterInputMilliwatts, let batteryPowerMilliwatts {
      systemPowerMilliwatts = max(0, adapterInputMilliwatts - max(0, batteryPowerMilliwatts))
    } else if externalPower == true, !isCharging {
      systemPowerMilliwatts = adapterInputMilliwatts
    } else {
      systemPowerMilliwatts = nil
    }

    let chargingPowerMilliwatts: Double?
    if !hasBattery {
      chargingPowerMilliwatts = nil
    } else if isCharging {
      if let batteryPowerMilliwatts, batteryPowerMilliwatts != 0 {
        chargingPowerMilliwatts = abs(batteryPowerMilliwatts)
      } else if let adapterInputMilliwatts, let systemLoadMilliwatts {
        chargingPowerMilliwatts = max(0, adapterInputMilliwatts - systemLoadMilliwatts)
      } else {
        chargingPowerMilliwatts = batteryPowerMilliwatts.map(abs)
      }
    } else {
      chargingPowerMilliwatts = 0
    }

    return PowerUsage(
      systemWatts: watts(systemPowerMilliwatts),
      chargingWatts: watts(chargingPowerMilliwatts),
      adapterInputWatts: watts(adapterInputMilliwatts),
      hasBattery: hasBattery,
      isExternalPowerConnected: externalPower,
      isCharging: isCharging
    )
  }

  private static func properties(for serviceClass: String) -> [String: Any]? {
    guard let matching = IOServiceMatching(serviceClass) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
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
    return properties
  }

  private static func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? UInt64 { return Double(value) }
    return nil
  }

  private static func nonnegative(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  private static func plausiblePower(_ value: Double?) -> Double? {
    guard let value, value.isFinite, abs(value) <= 1_000_000 else { return nil }
    return value
  }

  private static func calculatedBatteryPower(from properties: [String: Any]) -> Double? {
    guard
      let voltageMillivolts = number(properties["Voltage"]),
      let amperageMilliamps = number(properties["InstantAmperage"])
        ?? number(properties["Amperage"])
    else {
      return nil
    }
    return voltageMillivolts * amperageMilliamps / 1_000
  }

  private static func watts(_ milliwatts: Double?) -> Double? {
    guard let milliwatts, milliwatts.isFinite else { return nil }
    return milliwatts / 1_000
  }
}
