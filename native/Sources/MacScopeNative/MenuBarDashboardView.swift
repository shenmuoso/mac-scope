import AppKit
import Charts
import SwiftUI

struct MenuBarDashboardView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var navigation: AppNavigation
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(settings.menuBarModules.enumerated()), id: \.element.id) {
            index,
            module in
            moduleView(module)
            if index < settings.menuBarModules.count - 1 {
              Divider()
                .padding(.leading, 44)
            }
          }
        }
      }
      .compactNativeScrollers(clearsBackground: true)
      Divider()
      footer
    }
    .frame(width: 390, height: panelHeight)
    .background {
      if #available(macOS 26.0, *) {
        Color.clear
      } else {
        MenuBarPanelMaterialView()
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      updateProcessSampling()
    }
    .onDisappear {
      monitor.setProcessSampling(false, for: .menuBar)
    }
    .onChange(of: settings.menuBarModules) { _ in
      updateProcessSampling()
    }
  }

  private var panelHeight: CGFloat {
    let metricCount = settings.menuBarModules.filter { $0 != .processes }.count
    let processHeight =
      settings.menuBarModules.contains(.processes)
      ? 48 + CGFloat(settings.menuBarProcessLimit) * 32
      : 0
    return min(650, max(250, 112 + CGFloat(metricCount) * 82 + processHeight))
  }

  private var header: some View {
    HStack(spacing: 11) {
      MenuBarLogo(color: dashboardLogoColor)
        .frame(width: 27, height: 27)

      VStack(alignment: .leading, spacing: 2) {
        Text("MacScope")
          .font(.headline)
        if monitor.isPaused {
          Text("Monitoring Paused")
            .foregroundStyle(.secondary)
        } else {
          Text(
            "Updated \(metrics.snapshot.timestamp.formatted(date: .omitted, time: .standard))"
          )
          .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      Spacer()

      Button(action: monitor.togglePause) {
        Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .help(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring")

      Button(action: { monitor.refreshNow() }) {
        Image(systemName: "arrow.clockwise")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .help("Refresh Now")
      .disabled(monitor.isRefreshing)
    }
    .padding(.horizontal, 14)
    .frame(height: 60)
  }

  @ViewBuilder
  private func moduleView(_ module: MenuBarModule) -> some View {
    if module == .processes {
      MenuBarProcessesView(onSelect: openProcess)
    } else {
      MenuBarMetricRow(module: module)
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button(action: { openMainWindow() }) {
        Label("Open MacScope", systemImage: "macwindow")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)

      Spacer()

      Button(action: AppWindowActions.openSettings) {
        Image(systemName: "gearshape")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .help("Settings")

      Button {
        NSApp.terminate(nil)
      } label: {
        Image(systemName: "power")
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .help("Quit MacScope")
    }
    .padding(.horizontal, 14)
    .frame(height: 50)
  }

  private var dashboardLogoColor: Color {
    settings.menuBarColorfulMode ? settings.activeTheme.accentColor : .primary
  }

  private func updateProcessSampling() {
    monitor.setProcessSampling(settings.menuBarModules.contains(.processes), for: .menuBar)
  }

  private func openMainWindow() {
    openWindow(id: "main")
    DispatchQueue.main.async {
      AppWindowActions.activate()
      AppWindowActions.mainWindow?.makeKeyAndOrderFront(nil)
    }
  }

  private func openProcess(_ process: ProcessRow) {
    navigation.inspectProcess(process.pid)
    openMainWindow()
  }
}

private struct MenuBarMetricRow: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  let module: MenuBarModule

  var body: some View {
    let presentation = presentation
    HStack(spacing: 11) {
      Image(systemName: module.systemImage)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(presentation.accentColor)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(LocalizedStringKey(module.title))
            .font(.subheadline.weight(.semibold))
          Spacer(minLength: 4)
          Text(presentation.value)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(presentation.valueColor)
            .monospacedDigit()
        }

        Text(presentation.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)

        if let progress = presentation.progress {
          ProgressView(value: min(1, max(0, progress)))
            .progressViewStyle(.linear)
            .tint(presentation.progressColor)
        }
      }

      MetricSparkline(
        module: module,
        history: metrics.history,
        endDate: metrics.snapshot.timestamp,
        color: presentation.accentColor
      )
      .frame(width: 86, height: 40)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .frame(minHeight: 82)
  }

  private var presentation: MetricPresentation {
    let snapshot = metrics.snapshot
    let theme = settings.activeTheme
    let neutralAccent = Color.primary.opacity(0.68)
    let neutralProgress = Color.primary.opacity(0.5)

    func accent(_ colorfulColor: Color) -> Color {
      settings.menuBarColorfulMode ? colorfulColor : neutralAccent
    }

    func emphasizedValue(_ colorfulColor: Color) -> Color {
      settings.menuBarColorfulMode ? colorfulColor : .primary
    }

    func progress(_ colorfulColor: Color) -> Color {
      settings.menuBarColorfulMode ? colorfulColor : neutralProgress
    }

    switch module {
    case .cpu:
      return MetricPresentation(
        value: DisplayFormat.percent(snapshot.cpu.total),
        detail: localized(
          "User %@  System %@",
          DisplayFormat.percent(snapshot.cpu.user),
          DisplayFormat.percent(snapshot.cpu.system)
        ),
        accentColor: accent(theme.cpuColor),
        valueColor: .primary,
        progress: snapshot.cpu.total / 100,
        progressColor: progress(
          MetricColorScale.utilization(fraction: snapshot.cpu.total / 100)
        )
      )
    case .memory:
      return MetricPresentation(
        value: DisplayFormat.percent(snapshot.memory.fraction * 100),
        detail: localized(
          "Used %@ / %@",
          DisplayFormat.bytes(snapshot.memory.used),
          DisplayFormat.bytes(snapshot.memory.total)
        ),
        accentColor: accent(theme.memoryColor),
        valueColor: .primary,
        progress: snapshot.memory.fraction,
        progressColor: progress(
          MetricColorScale.utilization(fraction: snapshot.memory.fraction)
        )
      )
    case .disk:
      return MetricPresentation(
        value: DisplayFormat.percent(snapshot.disk.fraction * 100),
        detail:
          "↓ \(DisplayFormat.rate(snapshot.disk.readRate))  ↑ \(DisplayFormat.rate(snapshot.disk.writeRate))",
        accentColor: accent(theme.diskColor),
        valueColor: .primary,
        progress: snapshot.disk.fraction,
        progressColor: progress(
          MetricColorScale.utilization(fraction: snapshot.disk.fraction)
        )
      )
    case .network:
      let totalRate = snapshot.network.downloadRate + snapshot.network.uploadRate
      return MetricPresentation(
        value: "↓ \(DisplayFormat.rate(snapshot.network.downloadRate))",
        detail: "↑ \(DisplayFormat.rate(snapshot.network.uploadRate))",
        accentColor: accent(theme.networkColor),
        valueColor: emphasizedValue(MetricColorScale.network(rate: totalRate)),
        progress: nil,
        progressColor: .clear
      )
    case .temperature:
      let temperature = snapshot.cpu.temperature.socCelsius
      return MetricPresentation(
        value: DisplayFormat.temperature(temperature, unit: settings.temperatureUnit) ?? "--",
        detail: temperatureStatus(snapshot.cpu.temperature.status),
        accentColor: accent(MetricColorScale.temperature(celsius: temperature)),
        valueColor: emphasizedValue(MetricColorScale.temperature(celsius: temperature)),
        progress: nil,
        progressColor: .clear
      )
    case .systemPower:
      return MetricPresentation(
        value: DisplayFormat.power(snapshot.power.systemWatts) ?? "--",
        detail: systemPowerDetail(snapshot.power),
        accentColor: accent(.orange),
        valueColor: .primary,
        progress: nil,
        progressColor: .clear
      )
    case .chargingPower:
      return MetricPresentation(
        value: DisplayFormat.power(snapshot.power.chargingWatts) ?? "--",
        detail: chargingPowerDetail(snapshot.power),
        accentColor: accent(.green),
        valueColor: .primary,
        progress: nil,
        progressColor: .clear
      )
    case .processes:
      preconditionFailure("Processes use a dedicated module view")
    }
  }

  private func systemPowerDetail(_ power: PowerUsage) -> String {
    guard power.systemWatts != nil else { return localized("Power Telemetry Unavailable") }
    switch power.isExternalPowerConnected {
    case true: return localized("Connected to Power")
    case false: return localized("Using Battery")
    case nil: return localized("Live System Load")
    }
  }

  private func chargingPowerDetail(_ power: PowerUsage) -> String {
    guard power.hasBattery else { return localized("No Built-in Battery") }
    if power.isCharging { return localized("Charging") }
    if power.isExternalPowerConnected == true { return localized("Not Charging") }
    return localized("Using Battery")
  }

  private func temperatureStatus(_ status: ThermalStatus) -> String {
    switch status {
    case .unavailable: localized("Unavailable")
    case .normal: localized("Normal")
    case .warm: localized("Warm")
    case .hot: localized("Hot")
    }
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private struct MetricPresentation {
  let value: String
  let detail: String
  let accentColor: Color
  let valueColor: Color
  let progress: Double?
  let progressColor: Color
}

private struct MetricSparkPoint: Identifiable {
  let timestamp: Date
  let value: Double

  var id: Date { timestamp }
}

private struct MetricSparkline: View {
  let module: MenuBarModule
  let history: [SystemHistoryPoint]
  let endDate: Date
  let color: Color

  var body: some View {
    if points.count > 1 {
      Chart(points) { point in
        LineMark(
          x: .value("Time", point.timestamp),
          y: .value("Value", point.value)
        )
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      }
      .foregroundStyle(color)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartXScale(domain: endDate.addingTimeInterval(-60)...endDate)
      .chartYScale(domain: yDomain)
      .transaction { transaction in
        transaction.animation = nil
      }
    } else {
      Rectangle()
        .fill(Color.secondary.opacity(0.18))
        .frame(height: 1)
    }
  }

  private var points: [MetricSparkPoint] {
    history.compactMap { point in
      let value: Double?
      switch module {
      case .cpu:
        value = point.cpuPercent
      case .memory:
        value = point.memoryPercent
      case .disk:
        value = point.diskReadRate + point.diskWriteRate
      case .network:
        value = point.networkDownloadRate + point.networkUploadRate
      case .temperature:
        value = point.temperatureCelsius
      case .systemPower:
        value = point.systemPowerWatts
      case .chargingPower:
        value = point.chargingPowerWatts
      case .processes:
        value = nil
      }
      return value.map { MetricSparkPoint(timestamp: point.timestamp, value: $0) }
    }
  }

  private var yDomain: ClosedRange<Double> {
    switch module {
    case .cpu, .memory:
      return 0...100
    case .disk, .network:
      return 0...max(1, (points.map(\.value).max() ?? 0) * 1.12)
    case .systemPower, .chargingPower:
      return 0...max(1, (points.map(\.value).max() ?? 0) * 1.12)
    case .temperature:
      let values = points.map(\.value)
      let minimum = values.min() ?? 0
      let maximum = values.max() ?? minimum + 1
      let padding = max(2, (maximum - minimum) * 0.2)
      return (minimum - padding)...(maximum + padding)
    case .processes:
      return 0...1
    }
  }
}

private struct MenuBarProcessesView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings

  let onSelect: (ProcessRow) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Top Processes", systemImage: "list.number")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Picker("Process sorting", selection: $settings.menuBarProcessSort) {
          ForEach(MenuBarProcessSort.allCases) { sort in
            Text(LocalizedStringKey(sort.title)).tag(sort)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 94)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)

      if visibleProcesses.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Collecting process activity")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(settings.menuBarProcessLimit) * 32)
      } else {
        ForEach(visibleProcesses) { process in
          MenuBarProcessRow(
            process: process,
            value: value(for: process),
            action: { onSelect(process) }
          )
        }
      }
    }
  }

  private var visibleProcesses: [ProcessRow] {
    Array(monitor.processes.sorted(by: isHigherUsage).prefix(settings.menuBarProcessLimit))
  }

  private func isHigherUsage(_ lhs: ProcessRow, _ rhs: ProcessRow) -> Bool {
    switch settings.menuBarProcessSort {
    case .cpu:
      lhs.cpuPercent > rhs.cpuPercent
    case .memory:
      lhs.memoryBytes > rhs.memoryBytes
    case .disk:
      lhs.diskReadRate + lhs.diskWriteRate > rhs.diskReadRate + rhs.diskWriteRate
    case .network:
      lhs.networkDownloadRate + lhs.networkUploadRate
        > rhs.networkDownloadRate + rhs.networkUploadRate
    }
  }

  private func value(for process: ProcessRow) -> String {
    switch settings.menuBarProcessSort {
    case .cpu:
      DisplayFormat.percent(process.cpuPercent)
    case .memory:
      DisplayFormat.bytes(process.memoryBytes)
    case .disk:
      DisplayFormat.rate(process.diskReadRate + process.diskWriteRate)
    case .network:
      DisplayFormat.rate(process.networkDownloadRate + process.networkUploadRate)
    }
  }
}

private struct MenuBarProcessRow: View {
  let process: ProcessRow
  let value: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "app.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(process.name)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(value)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .font(.caption)
      .padding(.horizontal, 14)
      .frame(height: 32)
      .contentShape(Rectangle())
      .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Show Process Info")
  }
}
