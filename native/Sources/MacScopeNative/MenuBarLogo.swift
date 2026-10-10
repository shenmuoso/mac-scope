import AppKit
import SwiftUI

@MainActor
enum MenuBarLogoAsset {
  static let image = makeImage()

  private static func makeImage() -> NSImage {
    let image = NSImage(
      size: NSSize(width: 16, height: 16),
      flipped: true
    ) { bounds in
      draw(in: NSRect(x: bounds.minX, y: bounds.minY, width: 16, height: 16), color: .black)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "MacScope"
    return image
  }

  static func draw(in drawingBounds: NSRect, color: NSColor) {
    let unit = drawingBounds.width / 16
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
      NSPoint(x: drawingBounds.minX + x * unit, y: drawingBounds.minY + y * unit)
    }
    color.setStroke()
    let processor = NSBezierPath(
      roundedRect: NSRect(
        origin: point(3.25, 3.25), size: NSSize(width: 9.5 * unit, height: 9.5 * unit)
      ),
      xRadius: 2 * unit,
      yRadius: 2 * unit
    )
    processor.lineWidth = 1.4 * unit
    processor.stroke()

    let terminals = NSBezierPath()
    for position: CGFloat in [5, 8, 11] {
      terminals.move(to: point(position, 1))
      terminals.line(to: point(position, 3))
      terminals.move(to: point(position, 13))
      terminals.line(to: point(position, 15))
      terminals.move(to: point(1, position))
      terminals.line(to: point(3, position))
      terminals.move(to: point(13, position))
      terminals.line(to: point(15, position))
    }
    terminals.lineWidth = 1.4 * unit
    terminals.lineCapStyle = .round
    terminals.stroke()

    let activity = NSBezierPath()
    activity.move(to: point(5, 8.25))
    activity.line(to: point(6.25, 8.25))
    activity.line(to: point(7.25, 6.25))
    activity.line(to: point(8.75, 9.75))
    activity.line(to: point(9.75, 7.75))
    activity.line(to: point(11, 7.75))
    activity.lineWidth = 1.1 * unit
    activity.lineCapStyle = .round
    activity.lineJoinStyle = .round
    activity.stroke()
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

    MenuBarStatusPreview(presentation: presentation)
    .frame(width: MenuBarStatusLayout(metrics: presentation.metrics).width, height: 22)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }
}

struct MenuBarStatusPresentation {
  let snapshot: SystemSnapshot
  let displayMode: MenuBarDisplayMode
  let selectedMetrics: [MenuBarMetric]
  let temperatureUnit: TemperatureUnit

  var metrics: [MenuBarMetric] {
    guard displayMode == .compact else { return [] }
    return selectedMetrics.filter { $0 != .gpu || GPUMetricsReader.isSupported }
  }

  var compactText: String? {
    guard !metrics.isEmpty else { return nil }
    return metrics.map(value(for:)).joined(separator: " · ")
  }

  var accessibilityLabel: String {
    guard compactText != nil else { return "MacScope" }
    let values = metrics.map { metric in
      "\(metric.title), \(value(for: metric))"
    }.joined(separator: ", ")
    return "MacScope, \(values)"
  }

  func value(for metric: MenuBarMetric) -> String {
    switch metric {
    case .cpu:
      return "CPU \(DisplayFormat.compactPercent(snapshot.cpu.total))"
    case .gpu:
      return "GPU \(snapshot.gpu.totalPercent.map(DisplayFormat.compactPercent) ?? "--")"
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
