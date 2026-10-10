import AppKit
import SwiftUI

@MainActor
struct MenuBarStatusLayout {
  let metrics: [MenuBarMetric]

  static let font = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
    weight: .regular
  )
  static let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
  static let spacing: CGFloat = 10

  var width: CGFloat {
    guard !metrics.isEmpty else { return 22 }
    return 12 + 16 + Self.spacing
      + metrics.reduce(0) { $0 + width(for: $1) }
      + CGFloat(metrics.count - 1) * Self.spacing
  }

  func width(for metric: MenuBarMetric) -> CGFloat {
    // Reserve the formatted maximum instead of measuring each incoming sample.
    let reserved: String
    switch metric {
    case .cpu: reserved = "CPU 100%"
    case .gpu: reserved = "GPU 100%"
    case .memory: reserved = "MEM 100%"
    case .disk: reserved = "D↓999.9G ↑999.9G"
    case .network: reserved = "↓ 999+ GB/s"
    case .temperature: reserved = "-999°F"
    case .systemPower: reserved = "PWR 999.9W"
    case .chargingPower: reserved = "CHG 999.9W"
    case .fan: reserved = "FAN 30000RPM"
    }
    let font = metric == .network ? Self.networkFont : Self.font
    return ceil((reserved as NSString).size(withAttributes: [.font: font]).width) + 2
  }
}

@MainActor
final class MenuBarNativeStatusView: NSView {
  var presentation: MenuBarStatusPresentation? {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let presentation else { return }
    let layout = MenuBarStatusLayout(metrics: presentation.metrics)
    let isHighlighted = (superview as? NSStatusBarButton)?.isHighlighted ?? false
    let color = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
    let logoX: CGFloat = presentation.metrics.isEmpty ? (bounds.width - 16) / 2 : 6
    MenuBarLogoAsset.draw(
      in: NSRect(x: logoX, y: floor((bounds.height - 16) / 2), width: 16, height: 16),
      color: color
    )

    var x = logoX + 16 + MenuBarStatusLayout.spacing
    for metric in presentation.metrics {
      let width = layout.width(for: metric)
      if metric == .network {
        let rowHeight = bounds.height / 2
        drawText(
          "↓ \(DisplayFormat.menuBarRate(presentation.snapshot.network.downloadRate))",
          in: NSRect(x: x, y: 0, width: width, height: rowHeight),
          font: MenuBarStatusLayout.networkFont,
          color: color,
          alignment: .right
        )
        drawText(
          "↑ \(DisplayFormat.menuBarRate(presentation.snapshot.network.uploadRate))",
          in: NSRect(x: x, y: rowHeight, width: width, height: rowHeight),
          font: MenuBarStatusLayout.networkFont,
          color: color,
          alignment: .right
        )
      } else {
        drawText(
          presentation.value(for: metric),
          in: NSRect(x: x, y: 0, width: width, height: bounds.height),
          font: MenuBarStatusLayout.font,
          color: color,
          alignment: .left
        )
      }
      x += width + MenuBarStatusLayout.spacing
    }
  }

  private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
    let height = (text as NSString).size(withAttributes: attributes).height
    let textRect = NSRect(
      x: rect.minX,
      y: rect.midY - height / 2,
      width: rect.width,
      height: height
    )
    (text as NSString).draw(in: textRect, withAttributes: attributes)
  }
}

struct MenuBarStatusPreview: NSViewRepresentable {
  let presentation: MenuBarStatusPresentation

  func makeNSView(context: Context) -> MenuBarNativeStatusView {
    let view = MenuBarNativeStatusView()
    view.presentation = presentation
    return view
  }

  func updateNSView(_ view: MenuBarNativeStatusView, context: Context) {
    view.presentation = presentation
  }
}
