import AppKit
import Charts
import SwiftUI

struct HardwareInfoView: View {
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var store = HardwareInfoStore()

  var body: some View {
    VStack(spacing: 0) {
      HardwareDeviceHeader(snapshot: store.snapshot)

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
    }
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

private struct HardwareDeviceHeader: View {
  let snapshot: HardwareSnapshot?

  var body: some View {
    VStack(spacing: 6) {
      if let computerImage = NSImage(named: NSImage.computerName) {
        Image(nsImage: computerImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 210, height: 132)
          .accessibilityHidden(true)
      } else {
        Image(systemName: AppDestination.systemInfo.systemImage)
          .font(.system(size: 52, weight: .light))
          .foregroundStyle(.secondary)
          .frame(width: 210, height: 132)
          .accessibilityHidden(true)
      }

      Group {
        if let snapshot {
          Text(snapshot.machineName)
        } else {
          Text(AppDestination.systemInfo.title)
        }
      }
      .font(.title2.weight(.semibold))

      if let snapshot {
        Text("\(snapshot.chipName) · \(DisplayFormat.bytes(snapshot.memoryBytes))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text(AppDestination.systemInfo.pageDescription)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 190)
    .padding(.horizontal, 28)
    .padding(.vertical, 14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .frame(maxWidth: 880)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 14)
    .accessibilityElement(children: .combine)
  }
}

struct BatteryHealthView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var metrics: SystemMetricsStore
  @StateObject private var store = BatteryInfoStore()

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .battery)

      Group {
        if let battery = store.snapshot {
          batteryDashboard(battery)
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
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: store.refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh")
        .disabled(store.isLoading)
      }
    }
    .onAppear(perform: store.startMonitoring)
    .onDisappear(perform: store.stopMonitoring)
  }

  private func batteryDashboard(_ battery: BatterySnapshot) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)],
          spacing: 16
        ) {
          BatteryMetricGauge(
            title: "Current Charge",
            systemImage: batterySymbol(battery),
            value: battery.chargePercent / 100,
            valueText: DisplayFormat.compactPercent(battery.chargePercent),
            detail: chargeStatus(battery),
            tint: chargeColor(battery.chargePercent)
          )

          BatteryMetricGauge(
            title: "Maximum Capacity",
            systemImage: "heart.text.square",
            value: battery.healthPercent.map { $0 / 100 },
            valueText: battery.healthPercent.map(DisplayFormat.compactPercent) ?? "--",
            detail: conditionTitle(battery.condition),
            tint: battery.healthPercent.map(healthColor) ?? .secondary
          )

          BatteryMetricGauge(
            title: "Cycle Count",
            systemImage: "arrow.triangle.2.circlepath",
            value: cycleProgress(battery),
            valueText: String(battery.cycleCount),
            detail: cycleSummary(battery),
            tint: cycleColor(battery)
          )
        }

        if !capacityItems(battery).isEmpty {
          capacityPanel(battery)
        }

        HStack(alignment: .top, spacing: 16) {
          statusPanel(battery)
          electricalPanel(battery)
        }
      }
      .frame(maxWidth: 900)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.bottom, 28)
    }
    .compactNativeScrollers()
  }

  private func capacityPanel(_ battery: BatterySnapshot) -> some View {
    let items = capacityItems(battery)
    let maximum = Double(items.map(\.value).max() ?? 1) * 1.28

    return BatteryPanel(title: "Capacity Comparison") {
      Chart(items) { item in
        BarMark(
          x: .value("Capacity", item.value),
          y: .value("Type", localized(item.titleKey))
        )
        .foregroundStyle(item.color)
        .annotation(position: .trailing, alignment: .leading) {
          Text("\(item.value) mAh")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading) {
          AxisValueLabel()
        }
      }
      .chartXScale(domain: 0...maximum)
      .frame(height: CGFloat(items.count * 44 + 12))
    }
  }

  private func statusPanel(_ battery: BatterySnapshot) -> some View {
    BatteryPanel(title: "Battery Status") {
      VStack(spacing: 0) {
        BatteryDetailRow(
          title: "Power Source",
          systemImage: "powerplug",
          value: localized(battery.isExternalPowerConnected ? "Power Adapter" : "Battery")
        )
        if let minutes = battery.timeRemainingMinutes {
          Divider()
          BatteryDetailRow(
            title: battery.isCharging ? "Time to Full" : "Time Remaining",
            systemImage: "clock",
            value: DisplayFormat.duration(TimeInterval(minutes * 60))
          )
        }
        Divider()
        BatteryDetailRow(
          title: "Condition",
          systemImage: "heart",
          value: conditionTitle(battery.condition)
        )
        Divider()
        BatteryDetailRow(
          title: "Temperature",
          systemImage: "thermometer.medium",
          value: batteryTemperature(battery)
        )
      }
    }
  }

  private func electricalPanel(_ battery: BatterySnapshot) -> some View {
    BatteryPanel(title: "Electrical") {
      VStack(spacing: 0) {
        BatteryDetailRow(
          title: "Voltage",
          systemImage: "bolt",
          value: battery.voltageMillivolts.map {
            String(format: "%.2f V", Double($0) / 1_000)
          } ?? "--"
        )
        Divider()
        BatteryDetailRow(
          title: "Current",
          systemImage: "waveform.path",
          value: battery.amperageMilliamps.map { "\($0) mA" } ?? "--"
        )
      }
    }
  }

  private func capacityItems(_ battery: BatterySnapshot) -> [BatteryCapacityItem] {
    [
      battery.designCapacityMAh.map {
        BatteryCapacityItem(
          titleKey: "Design Capacity",
          value: $0,
          color: .secondary.opacity(0.55)
        )
      },
      battery.fullChargeCapacityMAh.map {
        BatteryCapacityItem(
          titleKey: "Full Charge Capacity",
          value: $0,
          color: .green.opacity(0.72)
        )
      },
      battery.remainingCapacityMAh.map {
        BatteryCapacityItem(titleKey: "Remaining Capacity", value: $0, color: .green)
      },
    ].compactMap { $0 }
  }

  private func batteryTemperature(_ battery: BatterySnapshot) -> String {
    let temperature = battery.temperatureCelsius ?? metrics.snapshot.cpu.temperature.batteryCelsius
    return DisplayFormat.temperature(temperature, unit: settings.temperatureUnit) ?? "--"
  }

  private func chargeStatus(_ battery: BatterySnapshot) -> String {
    if battery.isFullyCharged { return localized("Fully Charged") }
    if battery.isCharging { return localized("Charging") }
    if battery.isExternalPowerConnected { return localized("Connected to Power") }
    return localized("Using Battery")
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

  private func conditionTitle(_ condition: BatteryCondition) -> String {
    switch condition {
    case .normal: localized("Normal")
    case .serviceRecommended: localized("Service Recommended")
    case .unknown: localized("Unavailable")
    }
  }

  private func cycleProgress(_ battery: BatterySnapshot) -> Double? {
    guard let limit = battery.cycleLimit, limit > 0 else { return nil }
    return Double(battery.cycleCount) / Double(limit)
  }

  private func cycleColor(_ battery: BatterySnapshot) -> Color {
    guard let progress = cycleProgress(battery) else { return .secondary }
    if progress >= 0.9 { return .red }
    if progress >= 0.75 { return .orange }
    return .green
  }

  private func cycleSummary(_ battery: BatterySnapshot) -> String {
    guard let limit = battery.cycleLimit, limit > 0 else { return String(battery.cycleCount) }
    return "\(battery.cycleCount) / \(limit)"
  }

  private func localized(_ key: String) -> String {
    AppLocalization.string(key, language: settings.language)
  }
}

private struct BatteryMetricGauge: View {
  let title: LocalizedStringKey
  let systemImage: String
  let value: Double?
  let valueText: String
  let detail: String
  let tint: Color

  var body: some View {
    VStack(spacing: 10) {
      Gauge(value: min(1, max(0, value ?? 0))) {
        Label(title, systemImage: systemImage)
      } currentValueLabel: {
        Text(valueText)
          .font(.headline)
          .monospacedDigit()
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .tint(value == nil ? .secondary : tint)
      .controlSize(.large)
      .scaleEffect(1.18)
      .frame(width: 112, height: 102)

      Text(title)
        .font(.subheadline.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, minHeight: 160)
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct BatteryPanel<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct BatteryDetailRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  let value: String

  var body: some View {
    HStack(spacing: 10) {
      Label(title, systemImage: systemImage)
      Spacer(minLength: 12)
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(minHeight: 36)
  }
}

private struct BatteryCapacityItem: Identifiable {
  let titleKey: String
  let value: Int
  let color: Color

  var id: String { titleKey }
}
