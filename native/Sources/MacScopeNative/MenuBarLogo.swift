import AppKit
import SwiftUI

@MainActor
enum MenuBarLogoAsset {
  static let image = makeImage(trailingSpacing: 0)
  static let compactStatusImage = makeImage(trailingSpacing: 6)

  private static func makeImage(trailingSpacing: CGFloat) -> NSImage {
    let image = NSImage(
      size: NSSize(width: 16 + trailingSpacing, height: 16),
      flipped: true
    ) { bounds in
      let outlineWidth: CGFloat = 1.25
      let waveformWidth: CGFloat = 1.15
      let drawingBounds = NSRect(x: bounds.minX, y: bounds.minY, width: 16, height: 16)
      let symbolBounds = drawingBounds.insetBy(dx: 1, dy: 1)

      NSColor.black.setStroke()

      let outline = NSBezierPath(ovalIn: symbolBounds)
      outline.lineWidth = outlineWidth
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
          x: drawingBounds.minX + point.x * drawingBounds.width,
          y: drawingBounds.minY + point.y * drawingBounds.height
        )
        if index == 0 {
          waveform.move(to: scaled)
        } else {
          waveform.line(to: scaled)
        }
      }
      waveform.lineWidth = waveformWidth
      waveform.lineCapStyle = .round
      waveform.lineJoinStyle = .round
      waveform.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "MacScope"
    return image
  }
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

struct MenuBarStatusContent: View {
  let snapshot: SystemSnapshot
  let displayMode: MenuBarDisplayMode
  let selectedMetrics: [MenuBarMetric]
  let temperatureUnit: TemperatureUnit

  var body: some View {
    let presentation = MenuBarStatusPresentation(
      snapshot: snapshot,
      displayMode: displayMode,
      selectedMetrics: selectedMetrics,
      temperatureUnit: temperatureUnit
    )

    HStack(spacing: 10) {
      MenuBarLogo()
        .frame(width: 16, height: 16)

      if let compactText = presentation.compactText {
        Text(compactText)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }
}

struct MenuBarStatusPresentation {
  let snapshot: SystemSnapshot
  let displayMode: MenuBarDisplayMode
  let selectedMetrics: [MenuBarMetric]
  let temperatureUnit: TemperatureUnit

  var compactText: String? {
    guard displayMode == .compact, !selectedMetrics.isEmpty else { return nil }
    return selectedMetrics.map(value(for:)).joined(separator: " · ")
  }

  var accessibilityLabel: String {
    guard compactText != nil else { return "MacScope" }
    let values = selectedMetrics.map { metric in
      "\(metric.title), \(value(for: metric))"
    }.joined(separator: ", ")
    return "MacScope, \(values)"
  }

  func value(for metric: MenuBarMetric) -> String {
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
    case .fan:
      return "FAN \(DisplayFormat.compactFanSpeed(snapshot.cooling.fans.map(\.currentRPM).max()))"
    }
  }
}
