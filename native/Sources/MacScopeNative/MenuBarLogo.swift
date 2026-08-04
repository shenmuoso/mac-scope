import AppKit
import SwiftUI

@MainActor
private enum MenuBarLogoAsset {
  static let image: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
      let minimum = min(bounds.width, bounds.height)
      let lineWidth = max(1.5, minimum * 0.105)
      let symbolBounds = CGRect(
        x: bounds.midX - minimum / 2 + lineWidth / 2,
        y: bounds.midY - minimum / 2 + lineWidth / 2,
        width: minimum - lineWidth,
        height: minimum - lineWidth
      )

      NSColor.black.setStroke()

      let outline = NSBezierPath(ovalIn: symbolBounds)
      outline.lineWidth = lineWidth
      outline.stroke()

      let points: [CGPoint] = [
        CGPoint(x: 0.14, y: 0.54),
        CGPoint(x: 0.28, y: 0.54),
        CGPoint(x: 0.36, y: 0.39),
        CGPoint(x: 0.45, y: 0.71),
        CGPoint(x: 0.55, y: 0.27),
        CGPoint(x: 0.64, y: 0.59),
        CGPoint(x: 0.72, y: 0.46),
        CGPoint(x: 0.86, y: 0.46),
      ]
      let waveform = NSBezierPath()
      for (index, point) in points.enumerated() {
        let scaled = CGPoint(
          x: bounds.minX + point.x * bounds.width,
          y: bounds.minY + point.y * bounds.height
        )
        if index == 0 {
          waveform.move(to: scaled)
        } else {
          waveform.line(to: scaled)
        }
      }
      waveform.lineWidth = lineWidth
      waveform.lineCapStyle = .round
      waveform.lineJoinStyle = .round
      waveform.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "MacScope"
    return image
  }()
}

struct MenuBarLogo: View {
  var color: Color = .primary

  var body: some View {
    Image(nsImage: MenuBarLogoAsset.image)
      .resizable()
      .renderingMode(.template)
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(color)
      .accessibilityHidden(true)
  }
}

struct MenuBarStatusLabel: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    MenuBarStatusContent(
      snapshot: metrics.snapshot,
      displayMode: settings.menuBarDisplayMode,
      selectedMetrics: settings.menuBarMetrics,
      temperatureUnit: settings.temperatureUnit
    )
  }
}

struct MenuBarStatusContent: View {
  let snapshot: SystemSnapshot
  let displayMode: MenuBarDisplayMode
  let selectedMetrics: [MenuBarMetric]
  let temperatureUnit: TemperatureUnit

  var body: some View {
    HStack(spacing: 5) {
      MenuBarLogo()
        .frame(width: 17, height: 17)

      if displayMode == .compact, !selectedMetrics.isEmpty {
        Text(compactValue)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityValue)
  }

  private var compactValue: String {
    selectedMetrics.map(value(for:)).joined(separator: " · ")
  }

  private func value(for metric: MenuBarMetric) -> String {
    switch metric {
    case .cpu:
      return "CPU \(DisplayFormat.compactPercent(snapshot.cpu.total))"
    case .memory:
      return "MEM \(DisplayFormat.compactPercent(snapshot.memory.fraction * 100))"
    case .disk:
      return
        "D↓\(DisplayFormat.compactRate(snapshot.disk.readRate)) ↑\(DisplayFormat.compactRate(snapshot.disk.writeRate))"
    case .network:
      return
        "N↓\(DisplayFormat.compactRate(snapshot.network.downloadRate)) ↑\(DisplayFormat.compactRate(snapshot.network.uploadRate))"
    case .temperature:
      return DisplayFormat.temperature(
        snapshot.cpu.temperature.socCelsius,
        unit: temperatureUnit
      ) ?? "--°"
    case .systemPower:
      return "PWR \(DisplayFormat.compactPower(snapshot.power.systemWatts))"
    case .chargingPower:
      return "CHG \(DisplayFormat.compactPower(snapshot.power.chargingWatts))"
    }
  }

  private var accessibilityValue: String {
    guard displayMode == .compact, !selectedMetrics.isEmpty else { return "MacScope" }
    return selectedMetrics.map { metric in
      "\(metric.title), \(value(for: metric))"
    }.joined(separator: ", ")
  }
}
