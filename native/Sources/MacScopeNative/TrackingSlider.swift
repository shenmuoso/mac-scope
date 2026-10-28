import AppKit
import CoreAudio
import SwiftUI

/// AppKit slider whose thumb is not rebuilt by SwiftUI during a drag.
/// Each tick writes the percent label and the audio sink only. It does not
/// change SwiftUI state, so the tracking run loop does not lay out the page.
struct TrackingSlider: NSViewRepresentable {
  var value: Double
  var isEnabled: Bool = true
  var controlSize: NSControl.ControlSize = .regular
  var accessibilityLabel: String
  var deviceID: AudioObjectID = 0
  var input = false
  var hardware: HardwareVolumeRouter?
  var appKey: String?
  var appGains: AppGainRouter?
  var onEditingChanged: (Bool, Double) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onEditingChanged: onEditingChanged)
  }

  func makeNSView(context: Context) -> VolumeSliderBox {
    let slider = TrackingNSSlider()
    slider.minValue = 0
    slider.maxValue = 1
    slider.doubleValue = value
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.editingChanged = { [weak coordinator = context.coordinator] editing in
      guard let coordinator else { return }
      let current = coordinator.slider?.doubleValue ?? 0
      coordinator.isTracking = editing
      if !editing { coordinator.heldValue = current }
      coordinator.onEditingChanged(editing, current)
    }
    let box = VolumeSliderBox(slider: slider, compact: controlSize == .small)
    box.percent.stringValue = Self.percentText(value)
    context.coordinator.slider = slider
    context.coordinator.percent = box.percent
    return box
  }

  func updateNSView(_ box: VolumeSliderBox, context: Context) {
    let slider = box.slider
    let coordinator = context.coordinator
    slider.controlSize = controlSize
    slider.isEnabled = isEnabled
    slider.setAccessibilityLabel(accessibilityLabel)
    coordinator.onEditingChanged = onEditingChanged
    coordinator.hardware = hardware
    coordinator.appGains = appGains
    coordinator.appKey = appKey
    coordinator.deviceID = deviceID
    coordinator.input = input
    guard !coordinator.isTracking else { return }
    if let held = coordinator.heldValue {
      if abs(value - held) < 0.02 { coordinator.heldValue = nil }
      return
    }
    if abs(slider.doubleValue - value) > 0.000_1 {
      slider.doubleValue = value
      box.percent.stringValue = Self.percentText(value)
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: VolumeSliderBox, context: Context) -> CGSize? {
    let width = proposal.width ?? 180
    let height = max(nsView.fittingSize.height, controlSize == .small ? 16 : 20)
    return CGSize(width: width, height: height)
  }

  fileprivate static func percentText(_ value: Double) -> String {
    "\(Int((min(1, max(0, value)) * 100).rounded()))%"
  }
}

final class VolumeSliderBox: NSView {
  let slider: TrackingNSSlider
  let percent: StablePercentField

  init(slider: TrackingNSSlider, compact: Bool) {
    self.slider = slider
    percent = StablePercentField(labelWithString: "100%")
    super.init(frame: .zero)
    percent.font = .monospacedDigitSystemFont(
      ofSize: compact ? 11 : NSFont.systemFontSize,
      weight: .regular
    )
    percent.alignment = .right
    percent.textColor = .secondaryLabelColor
    percent.setContentHuggingPriority(.required, for: .horizontal)
    percent.setContentCompressionResistancePriority(.required, for: .horizontal)
    slider.translatesAutoresizingMaskIntoConstraints = false
    percent.translatesAutoresizingMaskIntoConstraints = false
    addSubview(slider)
    addSubview(percent)
    NSLayoutConstraint.activate([
      slider.leadingAnchor.constraint(equalTo: leadingAnchor),
      slider.centerYAnchor.constraint(equalTo: centerYAnchor),
      percent.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: compact ? 6 : 8),
      percent.trailingAnchor.constraint(equalTo: trailingAnchor),
      percent.centerYAnchor.constraint(equalTo: centerYAnchor),
      percent.widthAnchor.constraint(equalToConstant: compact ? 36 : 44),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }
}

extension TrackingSlider {
@MainActor
final class Coordinator: NSObject {
  var isTracking = false
  var heldValue: Double?
  var onEditingChanged: (Bool, Double) -> Void
  weak var slider: TrackingNSSlider?
  weak var percent: StablePercentField?
  var hardware: HardwareVolumeRouter?
  var appGains: AppGainRouter?
  var appKey: String?
  var deviceID: AudioObjectID = 0
  var input = false

  init(onEditingChanged: @escaping (Bool, Double) -> Void) {
    self.onEditingChanged = onEditingChanged
  }

  @objc func changed(_ sender: NSSlider) {
    let volume = sender.doubleValue
    if let hardware {
      hardware.setVolume(volume, deviceID: deviceID, input: input)
    } else if let appGains, let appKey {
      appGains.setGain(key: appKey, volume: volume)
    }
    percent?.stringValue = TrackingSlider.percentText(volume)
  }
}
}

/// System label whose text can change without invalidating Auto Layout.
/// The slider cell keeps the system glass tracking appearance.
final class StablePercentField: NSTextField {
  override func invalidateIntrinsicContentSize() {}
}

final class TrackingNSSlider: NSSlider {
  var editingChanged: ((Bool) -> Void)?

  override func mouseDown(with event: NSEvent) {
    editingChanged?(true)
    super.mouseDown(with: event)
    let ended = editingChanged
    DispatchQueue.main.async {
      ended?(false)
    }
  }
}
