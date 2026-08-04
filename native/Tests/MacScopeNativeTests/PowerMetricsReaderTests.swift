import Foundation
import Testing

@testable import MacScopeNative

@Suite("Power metrics")
struct PowerMetricsReaderTests {
  @Test("Power telemetry separates system load and battery charging")
  func separatesSystemAndChargingPower() {
    let telemetry: [String: Any] = [
      "SystemLoad": 18_000,
      "SystemPowerIn": 42_000,
      "BatteryPower": 24_000,
    ]
    let battery: [String: Any] = [
      "BatteryInstalled": true,
      "ExternalConnected": true,
      "IsCharging": true,
      "PowerTelemetryData": telemetry,
    ]

    let usage = PowerMetricsReader.parse(
      managerProperties: [:],
      batteryProperties: battery
    )

    #expect(usage.systemWatts == 18)
    #expect(usage.chargingWatts == 24)
    #expect(usage.adapterInputWatts == 42)
    #expect(usage.hasBattery)
    #expect(usage.isExternalPowerConnected == true)
    #expect(usage.isCharging)
  }

  @Test("Battery discharge is a system-power fallback")
  func usesBatteryDischargeFallback() {
    let batteryData: [String: Any] = ["BatteryPower": -12_500]
    let battery: [String: Any] = [
      "BatteryInstalled": true,
      "ExternalConnected": false,
      "IsCharging": false,
      "BatteryData": batteryData,
    ]

    let usage = PowerMetricsReader.parse(
      managerProperties: [:],
      batteryProperties: battery
    )

    #expect(usage.systemWatts == 12.5)
    #expect(usage.chargingWatts == 0)
    #expect(usage.adapterInputWatts == nil)
  }

  @Test("Charging power falls back to adapter input minus system load")
  func derivesChargingPowerFromInput() {
    let telemetry: [String: Any] = [
      "SystemLoad": 15_000,
      "SystemPowerIn": 25_000,
    ]
    let battery: [String: Any] = [
      "BatteryInstalled": true,
      "ExternalConnected": true,
      "IsCharging": true,
    ]

    let usage = PowerMetricsReader.parse(
      managerProperties: ["PowerTelemetryData": telemetry],
      batteryProperties: battery
    )

    #expect(usage.systemWatts == 15)
    #expect(usage.chargingWatts == 10)
  }

  @Test("Missing battery and telemetry remain unavailable")
  func preservesUnavailableState() {
    let usage = PowerMetricsReader.parse(
      managerProperties: [:],
      batteryProperties: [:]
    )

    #expect(usage == .unavailable)
  }

  @Test("Invalid unsigned power sentinels are rejected")
  func rejectsInvalidPowerSentinels() {
    let telemetry: [String: Any] = [
      "SystemLoad": UInt64.max,
      "SystemPowerIn": UInt64.max,
      "BatteryPower": UInt64.max,
    ]
    let battery: [String: Any] = [
      "BatteryInstalled": true,
      "ExternalConnected": true,
      "IsCharging": true,
    ]

    let usage = PowerMetricsReader.parse(
      managerProperties: ["PowerTelemetryData": telemetry],
      batteryProperties: battery
    )

    #expect(usage.systemWatts == nil)
    #expect(usage.chargingWatts == nil)
    #expect(usage.adapterInputWatts == nil)
  }

  @Test("Power menu items are disabled by default")
  @MainActor
  func defaultsKeepPowerItemsDisabled() throws {
    let suiteName = "PowerMetricsReaderTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)

    #expect(!settings.menuBarMetrics.contains(.systemPower))
    #expect(!settings.menuBarMetrics.contains(.chargingPower))
    #expect(!settings.menuBarModules.contains(.systemPower))
    #expect(!settings.menuBarModules.contains(.chargingPower))
  }
}
