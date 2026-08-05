import Charts
import SwiftUI

struct PerformancePowerView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .performancePower)

      ScrollView {
        VStack(spacing: 16) {
          statusMetrics
          cpuPanel
          powerPanel
          thermalPanel
          coolingPanel
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
      }
      .compactNativeScrollers()
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: monitor.togglePause) {
          Label(
            monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring",
            systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
          )
        }
        .help(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring")

        Button(action: { monitor.refreshNow(forceProcessSample: false) }) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh Now")
        .disabled(monitor.isRefreshing)
      }
    }
  }

  private var statusMetrics: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)],
      spacing: 12
    ) {
      PerformanceStatusMetric(
        title: "CPU Usage",
        systemImage: "cpu",
        value: DisplayFormat.percent(metrics.snapshot.cpu.total),
        detail: localized(
          "User %@  System %@",
          DisplayFormat.percent(metrics.snapshot.cpu.user),
          DisplayFormat.percent(metrics.snapshot.cpu.system)
        ),
        indicatorColor: MetricColorScale.utilization(
          fraction: metrics.snapshot.cpu.total / 100
        )
      )

      PerformanceStatusMetric(
        title: "System Power",
        systemImage: "bolt.fill",
        value: DisplayFormat.power(metrics.snapshot.power.systemWatts) ?? "--",
        detail: systemPowerDetail,
        indicatorColor: .orange
      )

      PerformanceStatusMetric(
        title: "SoC Temperature",
        systemImage: "thermometer.medium",
        value: DisplayFormat.temperature(
          metrics.snapshot.cpu.temperature.socCelsius,
          unit: settings.temperatureUnit
        ) ?? "--",
        detail: thermalStatusTitle,
        indicatorColor: MetricColorScale.temperature(
          celsius: metrics.snapshot.cpu.temperature.socCelsius
        )
      )

      PerformanceStatusMetric(
        title: "Fan Speed",
        systemImage: "fan",
        value: fanHeadline,
        detail: fanSupportDetail,
        indicatorColor: .secondary
      )
    }
  }

  private var cpuPanel: some View {
    PerformancePanel(title: "CPU Activity", subtitle: "Last 60 Seconds") {
      if metrics.history.count > 1 {
        Chart(metrics.history) { point in
          AreaMark(
            x: .value("Time", point.timestamp),
            y: .value("CPU", point.cpuPercent)
          )
          .foregroundStyle(
            .linearGradient(
              colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
              startPoint: .top,
              endPoint: .bottom
            )
          )

          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("CPU", point.cpuPercent)
          )
          .foregroundStyle(.blue)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
          AxisMarks(position: .leading)
        }
        .chartXScale(domain: historyDomain)
        .chartYScale(domain: 0...100)
        .frame(height: 180)
        .transaction { $0.animation = nil }
      } else {
        collectingView("Collecting CPU Activity")
      }
    }
  }

  private var powerPanel: some View {
    PerformancePanel(title: "Power Activity", subtitle: "Last 60 Seconds") {
      HStack(spacing: 24) {
        ChartLegendValue(
          title: "System Power",
          value: DisplayFormat.power(metrics.snapshot.power.systemWatts) ?? "--",
          color: .orange
        )
        ChartLegendValue(
          title: "Charging Power",
          value: DisplayFormat.power(metrics.snapshot.power.chargingWatts) ?? "--",
          color: .green
        )
        if metrics.snapshot.power.adapterInputWatts != nil {
          ChartLegendValue(
            title: "Adapter Input",
            value: DisplayFormat.power(metrics.snapshot.power.adapterInputWatts) ?? "--",
            color: .secondary
          )
        }
        Spacer(minLength: 0)
      }

      if powerSampleCount > 1 {
        Chart(powerPoints) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Power", point.watts),
            series: .value("Series", point.series.rawValue)
          )
          .foregroundStyle(point.series.color)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
          AxisMarks(position: .leading)
        }
        .chartXScale(domain: historyDomain)
        .chartYScale(domain: powerDomain)
        .frame(height: 180)
        .transaction { $0.animation = nil }
      } else {
        collectingView("Collecting Power Activity")
      }
    }
  }

  private var thermalPanel: some View {
    PerformancePanel(title: "Thermal Activity", subtitle: "Last 60 Seconds") {
      if temperaturePoints.count > 1 {
        Chart(temperaturePoints) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Temperature", displayedTemperature(point.celsius))
          )
          .foregroundStyle(
            MetricColorScale.temperature(celsius: metrics.snapshot.cpu.temperature.socCelsius)
          )
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
          AxisMarks(position: .leading)
        }
        .chartXScale(domain: historyDomain)
        .chartYScale(domain: temperatureDomain)
        .frame(height: 160)
        .transaction { $0.animation = nil }
      } else {
        collectingView("Collecting Temperature Activity", height: 160)
      }
    }
  }

  @ViewBuilder
  private var coolingPanel: some View {
    PerformancePanel(title: "Cooling", subtitle: coolingSubtitle) {
      switch metrics.snapshot.cooling.state {
      case .available:
        if fanSampleCount > 1 {
          Chart(fanPoints) { point in
            LineMark(
              x: .value("Time", point.timestamp),
              y: .value("Fan Speed", point.rpm),
              series: .value("Fan", point.name)
            )
            .foregroundStyle(by: .value("Fan", point.name))
            .interpolationMethod(.catmullRom)
            .lineStyle(chartLineStyle)
          }
          .chartForegroundStyleScale(range: fanChartColors)
          .chartXAxis(.hidden)
          .chartYAxis {
            AxisMarks(position: .leading)
          }
          .chartXScale(domain: historyDomain)
          .chartYScale(domain: fanDomain)
          .frame(height: 160)
          .transaction { $0.animation = nil }
        } else {
          collectingView("Collecting Fan Activity", height: 160)
        }

        Divider()
        fanDetails
      case .fanless:
        coolingCapabilityView(
          systemImage: "fan.slash",
          title: "Fanless Mac",
          message: "This Mac uses passive cooling and does not report a fan."
        )
      case .unavailable:
        coolingCapabilityView(
          systemImage: "fan",
          title: "Fan Telemetry Unavailable",
          message: "Fan speed is not exposed by this Mac. No administrator access is required."
        )
      }
    }
  }

  private var fanDetails: some View {
    VStack(spacing: 0) {
      ForEach(Array(metrics.snapshot.cooling.fans.enumerated()), id: \.element.id) {
        index,
        fan in
        if index > 0 { Divider() }
        HStack(spacing: 16) {
          Label {
            Text(localized("Fan %lld", fan.id + 1))
          } icon: {
            Image(systemName: "fan")
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          fanDetailValue("Current", value: fan.currentRPM)
          fanDetailValue("Minimum", value: fan.minimumRPM)
          fanDetailValue("Target", value: fan.targetRPM)
          fanDetailValue("Maximum", value: fan.maximumRPM)
        }
        .frame(minHeight: 52)
      }
    }
  }

  private func fanDetailValue(_ title: LocalizedStringKey, value: Double?) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(DisplayFormat.fanSpeed(value) ?? "--")
        .font(.subheadline)
        .monospacedDigit()
    }
    .frame(minWidth: 86, alignment: .trailing)
  }

  private func collectingView(_ title: LocalizedStringKey, height: CGFloat = 180) -> some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: height)
  }

  private func coolingCapabilityView(
    systemImage: String,
    title: LocalizedStringKey,
    message: LocalizedStringKey
  ) -> some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 150)
  }

  private var fanHeadline: String {
    guard metrics.snapshot.cooling.state == .available else { return "--" }
    return DisplayFormat.fanSpeed(
      metrics.snapshot.cooling.fans.map(\.currentRPM).max()
    ) ?? "--"
  }

  private var fanSupportDetail: String {
    switch metrics.snapshot.cooling.state {
    case .available:
      if metrics.snapshot.cooling.fans.count == 1 { return localized("1 Fan") }
      return localized("%lld Fans", metrics.snapshot.cooling.fans.count)
    case .fanless:
      return localized("Fanless Mac")
    case .unavailable:
      return localized("Fan Telemetry Unavailable")
    }
  }

  private var coolingSubtitle: LocalizedStringKey {
    metrics.snapshot.cooling.state == .available ? "Last 60 Seconds" : "Read Only"
  }

  private var systemPowerDetail: String {
    guard metrics.snapshot.power.systemWatts != nil else {
      return localized("Power Telemetry Unavailable")
    }
    switch metrics.snapshot.power.isExternalPowerConnected {
    case true: return localized("Connected to Power")
    case false: return localized("Using Battery")
    case nil: return localized("Live System Load")
    }
  }

  private var thermalStatusTitle: String {
    switch metrics.snapshot.cpu.temperature.status {
    case .unavailable: localized("Unavailable")
    case .normal: localized("Normal")
    case .warm: localized("Warm")
    case .hot: localized("Hot")
    }
  }

  private var historyDomain: ClosedRange<Date> {
    let endDate = metrics.snapshot.timestamp
    return endDate.addingTimeInterval(-60)...endDate
  }

  private var powerPoints: [PowerChartPoint] {
    metrics.history.flatMap { point in
      [
        point.systemPowerWatts.map {
          PowerChartPoint(timestamp: point.timestamp, watts: $0, series: .system)
        },
        point.chargingPowerWatts.map {
          PowerChartPoint(timestamp: point.timestamp, watts: $0, series: .charging)
        },
      ].compactMap { $0 }
    }
  }

  private var powerDomain: ClosedRange<Double> {
    0...max(1, (powerPoints.map(\.watts).max() ?? 0) * 1.15)
  }

  private var powerSampleCount: Int {
    Set(powerPoints.map(\.timestamp)).count
  }

  private var temperaturePoints: [TemperatureChartPoint] {
    metrics.history.compactMap { point in
      point.temperatureCelsius.map {
        TemperatureChartPoint(timestamp: point.timestamp, celsius: $0)
      }
    }
  }

  private var temperatureDomain: ClosedRange<Double> {
    let values = temperaturePoints.map { displayedTemperature($0.celsius) }
    let minimum = values.min() ?? 0
    let maximum = values.max() ?? minimum + 1
    let padding = max(settings.temperatureUnit == .celsius ? 2 : 4, (maximum - minimum) * 0.2)
    return (minimum - padding)...(maximum + padding)
  }

  private func displayedTemperature(_ celsius: Double) -> Double {
    switch settings.temperatureUnit {
    case .celsius: celsius
    case .fahrenheit: celsius * 9 / 5 + 32
    }
  }

  private var fanPoints: [FanChartPoint] {
    metrics.history.flatMap { point in
      point.fanReadings.map {
        FanChartPoint(
          timestamp: point.timestamp,
          fanID: $0.id,
          name: localized("Fan %lld", $0.id + 1),
          rpm: $0.rpm
        )
      }
    }
  }

  private var fanDomain: ClosedRange<Double> {
    0...max(1_000, (fanPoints.map(\.rpm).max() ?? 0) * 1.12)
  }

  private var fanSampleCount: Int {
    Set(fanPoints.map(\.timestamp)).count
  }

  private var fanChartColors: [Color] {
    [.blue, .teal, .indigo, .cyan]
  }

  private var chartLineStyle: StrokeStyle {
    StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private struct PerformanceStatusMetric: View {
  let title: LocalizedStringKey
  let systemImage: String
  let value: String
  let detail: String
  let indicatorColor: Color

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(indicatorColor)
        .frame(width: 26, height: 26)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct PerformancePanel<Content: View>: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  @ViewBuilder let content: Content

  init(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.headline)
        Spacer()
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct ChartLegendValue: View {
  let title: LocalizedStringKey
  let value: String
  let color: Color

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
      }
    }
  }
}

private struct PowerChartPoint: Identifiable {
  enum Series: String {
    case system
    case charging

    var color: Color {
      switch self {
      case .system: .orange
      case .charging: .green
      }
    }
  }

  let timestamp: Date
  let watts: Double
  let series: Series

  var id: String { "\(timestamp.timeIntervalSinceReferenceDate):\(series.rawValue)" }
}

private struct TemperatureChartPoint: Identifiable {
  let timestamp: Date
  let celsius: Double

  var id: Date { timestamp }
}

private struct FanChartPoint: Identifiable {
  let timestamp: Date
  let fanID: Int
  let name: String
  let rpm: Double

  var id: String { "\(timestamp.timeIntervalSinceReferenceDate):\(fanID)" }
}
