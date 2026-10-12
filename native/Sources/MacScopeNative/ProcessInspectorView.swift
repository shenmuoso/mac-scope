import AppKit
import Charts
import SwiftUI

struct ProcessInspectorView: View {
  let process: ProcessRow
  let history: [ProcessHistoryPoint]
  let theme: ThemePalette
  let onClose: () -> Void

  private var historyRange: ClosedRange<Date> {
    let end = history.last?.timestamp ?? .now
    return end.addingTimeInterval(-60)...end
  }

  var body: some View {
    Form {
      Section {
        header
      }
      activitySection
      cpuChart
      memoryChart
      ioChart
      generalSection
    }
    .formStyle(.grouped)
    .compactNativeScrollers()
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: processIcon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(process.name)
          .font(.headline)
          .lineLimit(1)
        Text("PID \(process.pid) · \(process.user)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Close Process Info")
    }
    .padding(.vertical, 4)
  }

  private var activitySection: some View {
    InspectorSection(title: "Activity") {
      LabeledContent("CPU") {
        Text(DisplayFormat.percent(process.cpuPercent))
      }
      LabeledContent("Memory") {
        Text(DisplayFormat.bytes(process.memoryBytes))
      }
      LabeledContent("Disk Read") {
        Text(DisplayFormat.rate(process.diskReadRate))
      }
      LabeledContent("Disk Write") {
        Text(DisplayFormat.rate(process.diskWriteRate))
      }
      LabeledContent("Download") {
        Text(DisplayFormat.rate(process.networkDownloadRate))
      }
      LabeledContent("Upload") {
        Text(DisplayFormat.rate(process.networkUploadRate))
      }
    }
    .monospacedDigit()
  }

  private var cpuChart: some View {
    InspectorSection(title: "CPU · Last 1 Minute") {
      Chart(history) { point in
        AreaMark(
          x: .value("Time", point.timestamp),
          y: .value("CPU", point.cpuPercent)
        )
        .foregroundStyle(theme.cpuColor.opacity(0.12))
        LineMark(
          x: .value("Time", point.timestamp),
          y: .value("CPU", point.cpuPercent)
        )
        .foregroundStyle(theme.cpuColor)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
      }
      .chartXScale(domain: historyRange)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let percent = value.as(Double.self) {
              Text("\(percent, specifier: "%.0f")%")
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var ioChart: some View {
    InspectorSection(title: "I/O · Last 1 Minute") {
      HStack(spacing: 12) {
        ChartLegend(color: theme.diskColor, title: "Disk")
        ChartLegend(color: theme.networkColor, title: "Network")
      }
      Chart {
        ForEach(history) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Disk", point.diskRate)
          )
          .foregroundStyle(theme.diskColor)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Network", point.networkRate)
          )
          .foregroundStyle(theme.networkColor)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
      }
      .chartXScale(domain: historyRange)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let rate = value.as(Double.self) {
              Text(DisplayFormat.rate(rate))
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var memoryChart: some View {
    InspectorSection(title: "Memory · Last 1 Minute") {
      Chart(history) { point in
        AreaMark(
          x: .value("Time", point.timestamp),
          y: .value("Memory", Double(point.memoryBytes))
        )
        .foregroundStyle(theme.memoryColor.opacity(0.12))
        LineMark(
          x: .value("Time", point.timestamp),
          y: .value("Memory", Double(point.memoryBytes))
        )
        .foregroundStyle(theme.memoryColor)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
      }
      .chartXScale(domain: historyRange)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let bytes = value.as(Double.self) {
              Text(DisplayFormat.bytes(UInt64(max(0, bytes))))
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var generalSection: some View {
    InspectorSection(title: "General") {
      LabeledContent("Software", value: process.software.name)
      LabeledContent("Source") {
        Text(originTitle)
      }
      if let bundleIdentifier = process.software.bundleIdentifier {
        LabeledContent("Bundle Identifier", value: bundleIdentifier)
      }
      LabeledContent("State", value: DisplayFormat.processState(process.state))
      LabeledContent("Parent PID", value: String(process.parentPID))
      LabeledContent("Threads", value: String(process.threadCount))
      LabeledContent("Runtime", value: DisplayFormat.duration(process.runtime))
      LabeledContent("Disk Read Total", value: DisplayFormat.bytes(process.diskReadTotal))
      LabeledContent("Disk Write Total", value: DisplayFormat.bytes(process.diskWriteTotal))
      LabeledContent("Downloaded", value: DisplayFormat.bytes(process.networkDownloadTotal))
      LabeledContent("Uploaded", value: DisplayFormat.bytes(process.networkUploadTotal))
      VStack(alignment: .leading, spacing: 4) {
        Text("Executable")
          .foregroundStyle(.secondary)
        Text(process.executablePath)
          .font(.caption)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var processIcon: NSImage {
    if let bundleURL = process.software.bundleURL {
      return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
    let iconPath: String
    if let appRange = process.executablePath.range(of: ".app/", options: .caseInsensitive) {
      iconPath = String(
        process.executablePath[..<process.executablePath.index(before: appRange.upperBound)])
    } else {
      iconPath = process.executablePath
    }
    guard FileManager.default.fileExists(atPath: iconPath) else {
      return NSImage(
        systemSymbolName: "gearshape.2",
        accessibilityDescription: "Process"
      ) ?? NSImage()
    }
    return NSWorkspace.shared.icon(forFile: iconPath)
  }

  private var originTitle: LocalizedStringKey {
    switch process.software.origin {
    case .macOSSystem: "System Software or Services"
    case .installedSoftware: "Installed Software"
    case .userTool: "Plug-ins or Tools"
    case .unknown: "Other"
    }
  }
}

private struct InspectorSection<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  var body: some View {
    Section(title) {
      content
    }
  }
}

private struct ChartLegend: View {
  let color: Color
  let title: LocalizedStringKey

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
