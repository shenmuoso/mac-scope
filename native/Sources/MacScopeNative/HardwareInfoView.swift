import AppKit
import SwiftUI

struct HardwareInfoView: View {
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var store = HardwareInfoStore()

  var body: some View {
    Group {
      if let snapshot = store.snapshot {
        hardwareList(snapshot)
      } else if store.isLoading {
        ProgressView("Loading System Information")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !store.errorMessage.isEmpty {
        SystemToolEmptyView(
          systemImage: "exclamationmark.triangle",
          title: "System Information Unavailable",
          message: "MacScope could not read the current hardware information."
        ) {
          Button("Try Again", action: store.refresh)
            .buttonStyle(.borderedProminent)
        }
      } else {
        ProgressView("Loading System Information")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("System Information")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button(action: copySummary) {
          Label("Copy Summary", systemImage: "doc.on.doc")
        }
        .help("Copy Summary")
        .disabled(store.snapshot == nil)

        Button(action: store.refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh")
        .disabled(store.isLoading)
      }
    }
    .onAppear {
      if store.snapshot == nil {
        store.refresh()
      }
    }
  }

  private func hardwareList(_ snapshot: HardwareSnapshot) -> some View {
    Form {
      Section {
        HStack(spacing: 16) {
          Image(systemName: "desktopcomputer")
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 44)

          VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.machineName)
              .font(.headline)
            Text("\(snapshot.chipName) · \(DisplayFormat.bytes(snapshot.memoryBytes))")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
      }

      Section("Mac") {
        infoRow("Model", value: snapshot.machineName, systemImage: "laptopcomputer")
        infoRow("Model Identifier", value: snapshot.modelIdentifier, systemImage: "number")
        infoRow("macOS", value: snapshot.operatingSystem, systemImage: "apple.logo")
        infoRow(
          "Uptime",
          value: DisplayFormat.duration(snapshot.uptime),
          systemImage: "clock"
        )
        statusRow(
          "Thermal State",
          value: thermalTitle(snapshot.thermalState),
          systemImage: "thermometer.medium",
          color: thermalColor(snapshot.thermalState)
        )
      }

      Section("Processor & Memory") {
        infoRow("Chip", value: snapshot.chipName, systemImage: "cpu")
        infoRow("Architecture", value: snapshot.architecture, systemImage: "terminal")
        infoRow(
          "CPU Cores",
          value: coreSummary(snapshot),
          systemImage: "circle.grid.3x3"
        )
        infoRow("Memory", value: DisplayFormat.bytes(snapshot.memoryBytes), systemImage: "memorychip")
      }

      Section("Storage") {
        infoRow(
          "Total Capacity",
          value: DisplayFormat.bytes(snapshot.storage.totalBytes),
          systemImage: "internaldrive"
        )
        infoRow(
          "Available",
          value: DisplayFormat.bytes(snapshot.storage.availableBytes),
          systemImage: "internaldrive.fill"
        )
      }

      Section("Displays") {
        if snapshot.displays.isEmpty {
          unavailableRow("No display information is available.")
        } else {
          ForEach(snapshot.displays) { display in
            HStack(spacing: 12) {
              Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(.secondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(display.name)
                  if display.isMain {
                    Text("Main")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Text("\(display.resolution) · \(display.pixelResolution)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("USB") {
        if snapshot.usbDevices.isEmpty {
          unavailableRow("No USB devices are currently reported.")
        } else {
          ForEach(snapshot.usbDevices) { device in
            HStack(spacing: 12) {
              Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(usbDetail(device))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("Bluetooth") {
        statusRow(
          "Status",
          value: connectionStatus(
            isAvailable: snapshot.bluetooth.isAvailable,
            isPoweredOn: snapshot.bluetooth.isPoweredOn
          ),
          systemImage: "wave.3.right",
          color: snapshot.bluetooth.isPoweredOn ? .green : .secondary
        )
        if snapshot.bluetooth.isAvailable {
          infoRow("Controller", value: snapshot.bluetooth.chipset, systemImage: "dot.radiowaves.left.and.right")
        }
        if snapshot.bluetooth.connectedDevices.isEmpty {
          unavailableRow("No Bluetooth devices are currently connected.")
        } else {
          ForEach(snapshot.bluetooth.connectedDevices) { device in
            HStack(spacing: 12) {
              Image(systemName: "headphones")
                .foregroundStyle(.secondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(bluetoothDetail(device))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("Wi-Fi") {
        statusRow(
          "Status",
          value: connectionStatus(
            isAvailable: snapshot.wifi.isAvailable,
            isPoweredOn: snapshot.wifi.isPoweredOn
          ),
          systemImage: "wifi",
          color: snapshot.wifi.isPoweredOn ? .green : .secondary
        )
        if snapshot.wifi.isAvailable {
          infoRow("Interface", value: snapshot.wifi.interfaceName, systemImage: "network")
          infoRow("Network", value: snapshot.wifi.ssid ?? "Unavailable", systemImage: "wifi")
          if let signal = snapshot.wifi.signalDBm {
            infoRow("Signal", value: "\(signal) dBm", systemImage: "chart.bar")
          }
          if let rate = snapshot.wifi.transmitRateMbps {
            infoRow(
              "Transmit Rate",
              value: String(format: "%.0f Mbps", rate),
              systemImage: "arrow.up.arrow.down"
            )
          }
          if let channel = snapshot.wifi.channel {
            infoRow("Channel", value: String(channel), systemImage: "antenna.radiowaves.left.and.right")
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: 880)
    .frame(maxWidth: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .compactNativeScrollers()
  }

  private func infoRow(_ title: LocalizedStringKey, value: String, systemImage: String) -> some View {
    LabeledContent {
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }

  private func statusRow(
    _ title: LocalizedStringKey,
    value: LocalizedStringKey,
    systemImage: String,
    color: Color
  ) -> some View {
    LabeledContent {
      Text(value)
        .foregroundStyle(color)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }

  private func unavailableRow(_ message: LocalizedStringKey) -> some View {
    Text(message)
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }

  private func coreSummary(_ snapshot: HardwareSnapshot) -> String {
    var summary = localized(
      "%lld physical · %lld logical",
      Int64(snapshot.physicalCores),
      Int64(snapshot.logicalCores)
    )
    if let performance = snapshot.performanceCores, let efficiency = snapshot.efficiencyCores {
      summary += " · " + localized(
        "%lld performance · %lld efficiency",
        Int64(performance),
        Int64(efficiency)
      )
    }
    return summary
  }

  private func thermalTitle(_ state: HardwareThermalState) -> LocalizedStringKey {
    switch state {
    case .nominal: "Normal"
    case .fair: "Elevated"
    case .serious: "High"
    case .critical: "Critical"
    case .unknown: "Unavailable"
    }
  }

  private func thermalColor(_ state: HardwareThermalState) -> Color {
    switch state {
    case .nominal: .green
    case .fair: .yellow
    case .serious: .orange
    case .critical: .red
    case .unknown: .secondary
    }
  }

  private func connectionStatus(isAvailable: Bool, isPoweredOn: Bool) -> LocalizedStringKey {
    guard isAvailable else { return "Unavailable" }
    return isPoweredOn ? "On" : "Off"
  }

  private func usbDetail(_ device: HardwareUSBDevice) -> String {
    [device.manufacturer, device.speed, device.productID, device.vendorID]
      .filter { $0 != "-" }
      .joined(separator: " · ")
  }

  private func bluetoothDetail(_ device: HardwareBluetoothDevice) -> String {
    var values = device.type == "-" ? [] : [device.type]
    if let signal = device.signal {
      values.append("\(signal) dBm")
    }
    return values.isEmpty ? localized("Connected") : values.joined(separator: " · ")
  }

  private func copySummary() {
    guard let snapshot = store.snapshot else { return }
    let lines = [
      "MacScope \(AppMetadata.version)",
      "\(localized("Model")): \(snapshot.machineName) (\(snapshot.modelIdentifier))",
      "\(localized("Chip")): \(snapshot.chipName)",
      "\(localized("CPU Cores")): \(coreSummary(snapshot))",
      "\(localized("Memory")): \(DisplayFormat.bytes(snapshot.memoryBytes))",
      "macOS: \(snapshot.operatingSystem)",
      "\(localized("Displays")): \(snapshot.displays.map(\.name).joined(separator: ", "))",
      "Wi-Fi: \(snapshot.wifi.isPoweredOn ? localized("On") : localized("Off"))",
      "Bluetooth: \(snapshot.bluetooth.isPoweredOn ? localized("On") : localized("Off"))",
    ]
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

struct BatteryHealthView: View {
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var store = BatteryInfoStore()

  var body: some View {
    Group {
      if let battery = store.snapshot {
        batteryList(battery)
      } else if store.isLoading || !store.hasLoaded {
        ProgressView("Reading Battery Information")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SystemToolEmptyView(
          systemImage: "battery.0percent",
          title: "No Built-in Battery",
          message: "This Mac does not report a built-in battery."
        ) {
          Button("Refresh", action: store.refresh)
        }
      }
    }
    .navigationTitle("Battery Health")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: store.refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh")
        .disabled(store.isLoading)
      }
    }
    .onAppear(perform: store.refresh)
  }

  private func batteryList(_ battery: BatterySnapshot) -> some View {
    Form {
      Section("Current Charge") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label(chargeStatus(battery), systemImage: batterySymbol(battery))
            Spacer()
            Text(DisplayFormat.compactPercent(battery.chargePercent))
              .font(.headline)
              .monospacedDigit()
          }
          ProgressView(value: battery.chargePercent, total: 100)
            .tint(chargeColor(battery.chargePercent))
        }
        .padding(.vertical, 4)

        batteryRow("Power Source", value: battery.isExternalPowerConnected ? "Power Adapter" : "Battery")
        if let minutes = battery.timeRemainingMinutes {
          batteryRow(
            battery.isCharging ? "Time to Full" : "Time Remaining",
            value: DisplayFormat.duration(TimeInterval(minutes * 60))
          )
        }
        batteryRow(
          "System Power",
          value: DisplayFormat.power(battery.systemPowerWatts) ?? "--"
        )
        batteryRow(
          "Charging Power",
          value: DisplayFormat.power(battery.chargingPowerWatts) ?? "--"
        )
      }

      Section("Health") {
        if let health = battery.healthPercent {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Maximum Capacity")
              Spacer()
              Text(DisplayFormat.compactPercent(health))
                .monospacedDigit()
            }
            ProgressView(value: health, total: 100)
              .tint(healthColor(health))
          }
          .padding(.vertical, 4)
        }
        batteryRow("Condition", value: conditionTitle(battery.condition))
        batteryRow("Cycle Count", value: cycleSummary(battery))
      }

      Section("Capacity") {
        if let value = battery.designCapacityMAh {
          batteryRow("Design Capacity", value: "\(value) mAh")
        }
        if let value = battery.fullChargeCapacityMAh {
          batteryRow("Full Charge Capacity", value: "\(value) mAh")
        }
        if let value = battery.remainingCapacityMAh {
          batteryRow("Remaining Capacity", value: "\(value) mAh")
        }
      }

      Section("Electrical") {
        if let value = battery.voltageMillivolts {
          batteryRow("Voltage", value: String(format: "%.2f V", Double(value) / 1_000))
        }
        if let value = battery.amperageMilliamps {
          batteryRow("Current", value: "\(value) mA")
        }
        if let value = battery.temperatureCelsius,
          let formatted = DisplayFormat.temperature(value, unit: settings.temperatureUnit)
        {
          batteryRow("Temperature", value: formatted)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: 760)
    .frame(maxWidth: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .compactNativeScrollers()
  }

  private func batteryRow(_ title: LocalizedStringKey, value: String) -> some View {
    LabeledContent(title) {
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private func batteryRow(_ title: LocalizedStringKey, value: LocalizedStringKey) -> some View {
    LabeledContent(title) {
      Text(value)
        .foregroundStyle(.secondary)
    }
  }

  private func chargeStatus(_ battery: BatterySnapshot) -> LocalizedStringKey {
    if battery.isFullyCharged { return "Fully Charged" }
    if battery.isCharging { return "Charging" }
    if battery.isExternalPowerConnected { return "Connected to Power" }
    return "Using Battery"
  }

  private func batterySymbol(_ battery: BatterySnapshot) -> String {
    if battery.isCharging { return "battery.100percent.bolt" }
    switch battery.chargePercent {
    case 75...: return "battery.100percent"
    case 50...: return "battery.75percent"
    case 25...: return "battery.50percent"
    default: return "battery.25percent"
    }
  }

  private func chargeColor(_ percent: Double) -> Color {
    percent < 20 ? .red : (percent < 40 ? .orange : .green)
  }

  private func healthColor(_ percent: Double) -> Color {
    percent < 70 ? .red : (percent < 80 ? .orange : .green)
  }

  private func conditionTitle(_ condition: BatteryCondition) -> LocalizedStringKey {
    switch condition {
    case .normal: "Normal"
    case .serviceRecommended: "Service Recommended"
    case .unknown: "Unavailable"
    }
  }

  private func cycleSummary(_ battery: BatterySnapshot) -> String {
    guard let limit = battery.cycleLimit, limit > 0 else { return String(battery.cycleCount) }
    return "\(battery.cycleCount) / \(limit)"
  }
}
