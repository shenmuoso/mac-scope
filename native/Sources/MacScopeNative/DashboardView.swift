import Charts
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  @State private var hoveredTimestamp: Date?

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .overview)

      ScrollView {
        overviewContent
          .frame(maxWidth: 980)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24)
          .padding(.bottom, 28)
      }
      .compactNativeScrollers()

      Divider()
      OverviewStatusBar(isPaused: monitor.isPaused)
    }
    .background(Color(nsColor: .windowBackgroundColor))
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

  private var overviewContent: some View {
    HStack(alignment: .top, spacing: 16) {
      metricColumn
        .frame(width: 250)

      activityTrends
        .frame(maxWidth: .infinity)
    }
  }

  private var metricColumn: some View {
    VStack(spacing: 0) {
      OverviewMetricRow(
        title: "CPU",
        systemImage: "cpu",
        value: DisplayFormat.percent(metrics.snapshot.cpu.total),
        detail: localized(
          "User %@  System %@",
          DisplayFormat.percent(metrics.snapshot.cpu.user),
          DisplayFormat.percent(metrics.snapshot.cpu.system)
        ),
        dial: .utilization(
          fraction: metrics.snapshot.cpu.total / 100,
          color: MetricColorScale.utilization(fraction: metrics.snapshot.cpu.total / 100)
        )
      )

      OverviewMetricDivider()

      OverviewMetricRow(
        title: "Memory",
        systemImage: "memorychip",
        value: DisplayFormat.percent(metrics.snapshot.memory.fraction * 100),
        detail: localized(
          "Used %@ / %@",
          DisplayFormat.bytes(metrics.snapshot.memory.used),
          DisplayFormat.bytes(metrics.snapshot.memory.total)
        ),
        dial: .utilization(
          fraction: metrics.snapshot.memory.fraction,
          color: MetricColorScale.utilization(fraction: metrics.snapshot.memory.fraction)
        )
      )

      OverviewMetricDivider()

      OverviewMetricRow(
        title: "Storage",
        systemImage: "internaldrive",
        value: DisplayFormat.percent(metrics.snapshot.disk.fraction * 100),
        detail: localized(
          "Used %@ / %@",
          DisplayFormat.bytes(metrics.snapshot.disk.used),
          DisplayFormat.bytes(metrics.snapshot.disk.total)
        ),
        dial: .utilization(
          fraction: metrics.snapshot.disk.fraction,
          color: MetricColorScale.utilization(fraction: metrics.snapshot.disk.fraction)
        )
      )

      OverviewMetricDivider()

      OverviewMetricRow(
        title: "Network",
        systemImage: "arrow.up.arrow.down",
        value: "↓ \(DisplayFormat.rate(metrics.snapshot.network.downloadRate))",
        detail: "↑ \(DisplayFormat.rate(metrics.snapshot.network.uploadRate))",
        dial: .traffic(
          downloadFraction: metrics.snapshot.network.downloadRate / networkReferenceRate,
          uploadFraction: metrics.snapshot.network.uploadRate / networkReferenceRate,
          color: settings.activeTheme.networkColor
        )
      )
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
  }

  private var activityTrends: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Activity Trends")
          .font(.headline)

        Spacer(minLength: 16)

        Group {
          if let hoveredTimestamp {
            Text(hoveredTimestamp.formatted(date: .omitted, time: .standard))
          } else {
            Text("Last 60 Seconds")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(minWidth: 112, alignment: .trailing)
      }
      .padding(.horizontal, 16)
      .frame(height: 48)

      Divider()

      if metrics.history.count > 1 {
        systemLoadTrack

        Divider()
          .padding(.leading, 16)

        diskActivityTrack

        Divider()
          .padding(.leading, 16)

        networkActivityTrack

        HStack {
          Text("60 Seconds Ago")
          Spacer()
          Text("Now")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
      } else {
        collectingView
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
  }

  private var systemLoadTrack: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        OverviewTrackTitle(title: "System Load", systemImage: "waveform.path.ecg")
        Spacer(minLength: 8)
        OverviewTrendValue(
          color: settings.activeTheme.cpuColor,
          title: "CPU",
          value: DisplayFormat.percent(presentedPoint?.cpuPercent ?? metrics.snapshot.cpu.total)
        )
        OverviewTrendValue(
          color: settings.activeTheme.memoryColor,
          title: "Memory",
          value: DisplayFormat.percent(
            presentedPoint?.memoryPercent ?? metrics.snapshot.memory.fraction * 100
          )
        )
      }

      Chart {
        RuleMark(y: .value("Midpoint", 50))
          .foregroundStyle(Color.primary.opacity(0.07))
          .lineStyle(StrokeStyle(lineWidth: 1))

        ForEach(metrics.history) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("CPU", point.cpuPercent),
            series: .value("Series", "CPU")
          )
          .foregroundStyle(settings.activeTheme.cpuColor)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)

          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Memory", point.memoryPercent),
            series: .value("Series", "Memory")
          )
          .foregroundStyle(settings.activeTheme.memoryColor)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }

        selectionRule
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartXScale(domain: historyDomain)
      .chartYScale(domain: 0...100)
      .frame(height: 96)
      .transaction { $0.animation = nil }
      .chartOverlay { proxy in
        chartHoverOverlay(proxy: proxy)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var diskActivityTrack: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        OverviewTrackTitle(title: "Disk Activity", systemImage: "internaldrive")
        Spacer(minLength: 8)
        OverviewTrendValue(
          color: settings.activeTheme.diskColor,
          title: "Read",
          value: DisplayFormat.rate(
            presentedPoint?.diskReadRate ?? metrics.snapshot.disk.readRate
          )
        )
        OverviewTrendValue(
          color: .secondary,
          title: "Write",
          value: DisplayFormat.rate(
            presentedPoint?.diskWriteRate ?? metrics.snapshot.disk.writeRate
          )
        )
      }

      Chart {
        RuleMark(y: .value("Midpoint", diskRateDomain.upperBound / 2))
          .foregroundStyle(Color.primary.opacity(0.07))
          .lineStyle(StrokeStyle(lineWidth: 1))

        ForEach(metrics.history) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Read", point.diskReadRate),
            series: .value("Series", "Read")
          )
          .foregroundStyle(settings.activeTheme.diskColor)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)

          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Write", point.diskWriteRate),
            series: .value("Series", "Write")
          )
          .foregroundStyle(Color.secondary)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }

        selectionRule
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartXScale(domain: historyDomain)
      .chartYScale(domain: diskRateDomain)
      .frame(height: 82)
      .transaction { $0.animation = nil }
      .chartOverlay { proxy in
        chartHoverOverlay(proxy: proxy)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var networkActivityTrack: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        OverviewTrackTitle(title: "Network Activity", systemImage: "network")
        Spacer(minLength: 8)
        OverviewTrendValue(
          color: settings.activeTheme.networkColor,
          title: "Download",
          value: DisplayFormat.rate(
            presentedPoint?.networkDownloadRate ?? metrics.snapshot.network.downloadRate
          )
        )
        OverviewTrendValue(
          color: .secondary,
          title: "Upload",
          value: DisplayFormat.rate(
            presentedPoint?.networkUploadRate ?? metrics.snapshot.network.uploadRate
          )
        )
      }

      Chart {
        RuleMark(y: .value("Midpoint", networkRateDomain.upperBound / 2))
          .foregroundStyle(Color.primary.opacity(0.07))
          .lineStyle(StrokeStyle(lineWidth: 1))

        ForEach(metrics.history) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Download", point.networkDownloadRate),
            series: .value("Series", "Download")
          )
          .foregroundStyle(settings.activeTheme.networkColor)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)

          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Upload", point.networkUploadRate),
            series: .value("Series", "Upload")
          )
          .foregroundStyle(Color.secondary)
          .interpolationMethod(.catmullRom)
          .lineStyle(chartLineStyle)
        }

        selectionRule
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartXScale(domain: historyDomain)
      .chartYScale(domain: networkRateDomain)
      .frame(height: 82)
      .transaction { $0.animation = nil }
      .chartOverlay { proxy in
        chartHoverOverlay(proxy: proxy)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ChartContentBuilder
  private var selectionRule: some ChartContent {
    if let hoveredTimestamp {
      RuleMark(x: .value("Selected Time", hoveredTimestamp))
        .foregroundStyle(Color.secondary.opacity(0.38))
        .lineStyle(StrokeStyle(lineWidth: 1))
    }
  }

  private func chartHoverOverlay(proxy: ChartProxy) -> some View {
    GeometryReader { geometry in
      Rectangle()
        .fill(.clear)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            let plotFrame = geometry[proxy.plotAreaFrame]
            guard plotFrame.contains(location) else {
              hoveredTimestamp = nil
              return
            }
            hoveredTimestamp = proxy.value(atX: location.x - plotFrame.minX)
          case .ended:
            hoveredTimestamp = nil
          }
        }
    }
  }

  private var collectingView: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Collecting System Activity")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 412)
  }

  private var presentedPoint: SystemHistoryPoint? {
    guard let hoveredTimestamp else { return metrics.history.last }
    return metrics.history.min {
      abs($0.timestamp.timeIntervalSince(hoveredTimestamp))
        < abs($1.timestamp.timeIntervalSince(hoveredTimestamp))
    }
  }

  private var historyDomain: ClosedRange<Date> {
    let endDate = metrics.snapshot.timestamp
    return endDate.addingTimeInterval(-60)...endDate
  }

  private var diskRateDomain: ClosedRange<Double> {
    let maximum = metrics.history.flatMap { [$0.diskReadRate, $0.diskWriteRate] }.max() ?? 0
    return 0...max(1, maximum * 1.12)
  }

  private var networkRateDomain: ClosedRange<Double> {
    let maximum = metrics.history.flatMap {
      [$0.networkDownloadRate, $0.networkUploadRate]
    }.max() ?? 0
    return 0...max(1, maximum * 1.12)
  }

  private var networkReferenceRate: Double {
    max(
      1,
      metrics.history.flatMap {
        [$0.networkDownloadRate, $0.networkUploadRate]
      }.max() ?? 0,
      metrics.snapshot.network.downloadRate,
      metrics.snapshot.network.uploadRate
    )
  }

  private var chartLineStyle: StrokeStyle {
    StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private enum OverviewMetricDialStyle {
  case utilization(fraction: Double, color: Color)
  case traffic(
    downloadFraction: Double,
    uploadFraction: Double,
    color: Color
  )
}

private struct OverviewMetricRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  let value: String
  let detail: String
  let dial: OverviewMetricDialStyle

  var body: some View {
    HStack(spacing: 14) {
      OverviewMetricDial(systemImage: systemImage, style: dial)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)

        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(height: 110)
    .accessibilityElement(children: .combine)
  }
}

private struct OverviewMetricDial: View {
  let systemImage: String
  let style: OverviewMetricDialStyle

  var body: some View {
    ZStack {
      switch style {
      case .utilization(let fraction, let color):
        Circle()
          .stroke(Color.primary.opacity(0.09), lineWidth: 6)

        Circle()
          .trim(from: 0, to: min(1, max(0, fraction)))
          .stroke(
            color,
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
          )
          .rotationEffect(.degrees(-90))

      case .traffic(let downloadFraction, let uploadFraction, let color):
        Circle()
          .stroke(Color.primary.opacity(0.09), lineWidth: 5)

        Circle()
          .trim(from: 0, to: min(1, max(0, downloadFraction)))
          .stroke(
            color,
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
          )
          .rotationEffect(.degrees(-90))

        Circle()
          .stroke(Color.primary.opacity(0.07), lineWidth: 3)
          .frame(width: 42, height: 42)

        Circle()
          .trim(from: 0, to: min(1, max(0, uploadFraction)))
          .stroke(
            Color.secondary,
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
          )
          .rotationEffect(.degrees(-90))
          .frame(width: 42, height: 42)
      }

      Image(systemName: systemImage)
        .symbolRenderingMode(.monochrome)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(width: 60, height: 60)
    .accessibilityHidden(true)
  }
}

private struct OverviewMetricDivider: View {
  var body: some View {
    Divider()
      .padding(.leading, 90)
  }
}

private struct OverviewTrackTitle: View {
  let title: LocalizedStringKey
  let systemImage: String

  var body: some View {
    Label {
      Text(title)
        .foregroundStyle(.primary)
    } icon: {
      Image(systemName: systemImage)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.secondary)
    }
    .font(.subheadline.weight(.semibold))
    .lineLimit(1)
  }
}

private struct OverviewTrendValue: View {
  let color: Color
  let title: LocalizedStringKey
  let value: String

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(title)
        .foregroundStyle(.secondary)

      Text(value)
        .foregroundStyle(.primary)
        .monospacedDigit()
    }
    .font(.caption)
    .lineLimit(1)
    .minimumScaleFactor(0.78)
  }
}

private struct OverviewStatusBar: View {
  @EnvironmentObject private var metrics: SystemMetricsStore

  let isPaused: Bool

  var body: some View {
    HStack {
      if isPaused {
        Label("Monitoring Paused", systemImage: "pause.circle.fill")
          .foregroundStyle(.secondary)
      } else {
        Text("Updated \(metrics.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("Last 60 Seconds")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 28)
  }
}
