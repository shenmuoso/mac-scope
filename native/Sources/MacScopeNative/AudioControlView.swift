import AppKit
import CoreAudio
import SwiftUI

struct AudioControlView: View {
  @EnvironmentObject private var controller: AppAudioController
  @State private var equalizerKey: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DetailLayout.groupSpacing) {
        deviceSection(
          "Input",
          devices: controller.inputDevices,
          defaultUID: controller.input.deviceUID,
          input: true
        )
        deviceSection(
          "Output",
          devices: controller.outputDevices,
          defaultUID: controller.output.deviceUID,
          input: false
        )
        applicationSection
      }
      .padding(.top, 16)
      .padding(.horizontal, DetailLayout.pageInset)
      .padding(.bottom, 24)
      .frame(maxWidth: 1040, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
    .compactNativeScrollers()
  }

  private func deviceSection(
    _ title: LocalizedStringKey,
    devices: [AudioOutputDevice],
    defaultUID: String?,
    input: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      if devices.isEmpty {
        Text("Volume Unavailable")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(devices) { device in
          deviceRow(device, isDefault: device.uid == defaultUID, input: input)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .detailGroup()
  }

  private func deviceRow(_ device: AudioOutputDevice, isDefault: Bool, input: Bool) -> some View {
    HStack(spacing: 10) {
      Button {
        Task {
          if input {
            await controller.setDefaultInputDevice(device.uid)
          } else {
            await controller.setDefaultOutputDevice(device.uid)
          }
        }
      } label: {
        HStack(spacing: 8) {
          Image(
            systemName: AppAudioDeviceSymbol.systemImage(name: device.name, transport: device.transport)
          )
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(isDefault ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .frame(width: 26, height: 26)
          .background {
            if isDefault {
              Circle().fill(Color.accentColor)
            }
          }
          Text(verbatim: device.name)
            .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isDefault ? .isSelected : [])
      .frame(width: 220, alignment: .leading)
      muteButton(isMuted: device.isMuted, enabled: device.canChangeVolume) {
        controller.setDeviceMuted(!device.isMuted, uid: device.uid, input: input)
      }
      DeviceVolumeControl(
        uid: device.uid,
        volume: device.volume,
        isEnabled: device.canChangeVolume,
        name: device.name,
        input: input,
        deviceID: device.objectID
      )
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var applicationSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Application Volumes")
        .font(.headline)
      if AppAudioRoute.isPerAppSupported {
        if controller.apps.isEmpty {
          Text("No Application Audio")
          Text("Apps appear here while they are playing audio.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          ForEach(controller.apps) { row in
            VStack(alignment: .leading, spacing: 8) {
              applicationRow(row)
              if equalizerKey == row.key {
                AppAudioEqualizerView(gains: row.level.eqGains) { gains in
                  Task { await controller.setEQ(gains, for: row.key) }
                }
              }
            }
          }
        }
        if let errorKey = controller.perAppErrorKey {
          VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(errorKey))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let status = controller.lastTapStatus, status != 0 {
              Text(verbatim: "OSStatus \(status)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
            Button(action: SystemPermission.openSystemAudioSettings) {
              Label("Open System Settings", systemImage: "lock.open")
            }
          }
        }
      } else {
        Text("Per-app Volume Unavailable")
        Text("Per-app volume requires macOS 14.2 or later.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .detailGroup()
  }

  private func applicationRow(_ row: AppAudioRow) -> some View {
    HStack(spacing: 8) {
      AppAudioLevelMeter(source: controller.levelMeters, key: row.key)
      Image(nsImage: icon(for: row))
        .resizable()
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: row.name)
          .lineLimit(1)
        subtitle(for: row)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 156, alignment: .leading)
      muteButton(isMuted: row.level.isMuted, enabled: true) {
        Task { await controller.setMuted(!row.level.isMuted, for: row.key) }
      }
      AppVolumeControl(
        rowKey: row.key,
        volume: row.level.volume,
        isEnabled: row.isPlaying || AppAudioRoute.needsTap(row.level, systemDeviceUID: controller.output.deviceUID),
        name: row.name
      )
      boostMenu(for: row)
      deviceMenu(for: row)
      Button {
        equalizerKey = equalizerKey == row.key ? nil : row.key
      } label: {
        Image(systemName: "slider.vertical.3")
          .frame(width: 22)
          .foregroundStyle(
            equalizerKey == row.key || !AppAudioEQ.isFlat(row.level.eqGains)
              ? AnyShapeStyle(.tint)
              : AnyShapeStyle(.secondary)
          )
      }
      .buttonStyle(.borderless)
      .help("Equalizer")
      .accessibilityLabel("Equalizer")
    }
    .padding(.vertical, 4)
  }

  private func muteButton(isMuted: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .frame(width: 18)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(isMuted ? Text("Unmute") : Text("Mute"))
    .accessibilityLabel(isMuted ? Text("Unmute") : Text("Mute"))
  }

  private func boostMenu(for row: AppAudioRow) -> some View {
    Menu {
      ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { factor in
        Button {
          Task { await controller.setBoost(factor, for: row.key) }
        } label: {
          deviceChoice(Text(verbatim: "\(Int(factor))×"), selected: row.level.boost == factor)
        }
      }
    } label: {
      Image(systemName: "chevron.up.chevron.down")
        .frame(width: 18)
        .foregroundStyle(row.level.boost > 1 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Volume Boost")
    .accessibilityLabel("Volume Boost")
  }

  private func deviceMenu(for row: AppAudioRow) -> some View {
    let multiple = row.level.routesToMultipleDevices
    return Menu {
      Button {
        Task { await controller.setMultipleRoutes(false, for: row.key) }
      } label: {
        deviceChoice(Text("Single"), selected: !multiple)
      }
      Button {
        Task { await controller.setMultipleRoutes(true, for: row.key) }
      } label: {
        deviceChoice(Text("Multi"), selected: multiple)
      }
      Divider()
      if multiple {
        Button {} label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("Follow System")
            Text("Not available in multi mode")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(true)
      } else {
        Button {
          Task { await controller.setAppOutputDevices([], for: row.key) }
        } label: {
          deviceChoice(Text("Follow System"), selected: row.level.outputDeviceUIDs.isEmpty)
        }
      }
      ForEach(controller.outputDevices) { device in
        Button {
          if multiple {
            Task { await controller.toggleAppOutputDevice(device.uid, for: row.key) }
          } else {
            Task { await controller.setAppOutputDevices([device.uid], for: row.key) }
          }
        } label: {
          HStack {
            deviceChoice(
              Text(verbatim: device.name),
              selected: row.level.outputDeviceUIDs.contains(device.uid) && (multiple || !row.level.outputDeviceUIDs.isEmpty)
            )
            if device.uid == controller.output.deviceUID {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
            }
          }
        }
      }
    } label: {
      deviceMenuLabel(for: row)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Output Device")
    .accessibilityLabel("Output Device")
  }

  private func deviceMenuLabel(for row: AppAudioRow) -> some View {
    let count = row.level.outputDeviceUIDs.count
    return Image(systemName: deviceSymbol(for: row))
      .frame(width: 22)
      .overlay(alignment: .topTrailing) {
        if row.level.routesToMultipleDevices && count > 1 {
          Text(verbatim: "\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(2)
            .background(Circle().fill(Color.accentColor))
            .offset(x: 6, y: -6)
        }
      }
  }

  @ViewBuilder
  private func subtitle(for row: AppAudioRow) -> some View {
    if row.level.routesToMultipleDevices {
      Text("Multi · \(row.level.outputDeviceUIDs.count) devices")
    } else if row.isPlaying || !row.level.outputDeviceUIDs.isEmpty {
      Text(verbatim: deviceName(for: row))
    } else {
      Text("Not Playing")
    }
  }

  private func deviceName(for row: AppAudioRow) -> String {
    if let uid = row.level.outputDeviceUIDs.first,
      let device = controller.outputDevices.first(where: { $0.uid == uid })
    {
      return device.name
    }
    return controller.output.deviceName.isEmpty ? "—" : controller.output.deviceName
  }

  private func deviceChoice(_ title: Text, selected: Bool) -> some View {
    HStack {
      title
      if selected {
        Image(systemName: "checkmark")
      }
    }
  }

  private func deviceSymbol(for row: AppAudioRow) -> String {
    let uid = row.level.outputDeviceUIDs.first ?? controller.output.deviceUID
    guard let uid, let device = controller.outputDevices.first(where: { $0.uid == uid }) else {
      return "speaker.wave.2"
    }
    return AppAudioDeviceSymbol.systemImage(name: device.name, transport: device.transport)
  }

  private func icon(for row: AppAudioRow) -> NSImage {
    if let path = row.bundlePath {
      return WorkspaceIconCache.icon(for: URL(fileURLWithPath: path))
    }
    return NSImage(named: NSImage.applicationIconName) ?? NSImage()
  }
}

private struct DeviceVolumeControl: View {
  @EnvironmentObject private var controller: AppAudioController
  let uid: String
  let volume: Double
  let isEnabled: Bool
  let name: String
  let input: Bool
  let deviceID: AudioObjectID

  var body: some View {
    TrackingSlider(
      value: volume,
      isEnabled: isEnabled,
      accessibilityLabel: name,
      deviceID: deviceID,
      input: input,
      hardware: controller.hardwareVolumes,
      onEditingChanged: { isEditing, current in
        if isEditing {
          controller.beginVolumeDrag()
          controller.setDeviceEditing(uid)
        } else {
          controller.endDeviceVolumeDrag(uid: uid, input: input, volume: current)
        }
      }
    )
    .frame(maxWidth: .infinity)
  }
}

private struct AppAudioLevelMeter: View {
  @ObservedObject var source: AppAudioMeters
  let key: String

  var body: some View {
    let meter = source.values[key] ?? .silent
    HStack(spacing: 3) {
      levelBar(meter.left)
      levelBar(meter.right)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Level")
  }

  private func levelBar(_ level: Double) -> some View {
    GeometryReader { proxy in
      let amount = AppAudioMeter.visual(level)
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(Color.primary.opacity(0.12))
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(Color.accentColor)
          .frame(height: proxy.size.height * amount)
      }
    }
    .frame(width: 4, height: 28)
  }
}

private struct AppVolumeControl: View {
  @EnvironmentObject private var controller: AppAudioController
  let rowKey: String
  let volume: Double
  let isEnabled: Bool
  let name: String

  var body: some View {
    TrackingSlider(
      value: volume,
      isEnabled: isEnabled,
      accessibilityLabel: name,
      appKey: rowKey,
      appGains: controller.appGains,
      onEditingChanged: { isEditing, current in
        if isEditing {
          controller.beginVolumeDrag()
        } else {
          controller.finishAppVolumeDrag(key: rowKey, volume: current)
        }
      }
    )
    .frame(maxWidth: .infinity)
  }
}

private struct AppAudioEqualizerView: View {
  let gains: [Double]
  let onChange: ([Double]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Equalizer")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("Flat") {
          onChange(AppAudioEQ.flat)
        }
        .controlSize(.small)
      }
      HStack(alignment: .bottom, spacing: 12) {
        ForEach(Array(AppAudioEQ.frequencies.enumerated()), id: \.offset) { index, frequency in
          VStack(spacing: 6) {
            Text(verbatim: decibelText(band(index)))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
            EqualizerBandSlider(
              value: Binding(
                get: { band(index) },
                set: { value in
                  var next = AppAudioEQ.normalized(gains)
                  next[index] = value
                  onChange(next)
                }
              )
            )
            .frame(height: 120)
            Text(verbatim: frequencyLabel(frequency))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(verbatim: frequencyLabel(frequency)))
          .accessibilityValue(Text(verbatim: decibelText(band(index))))
          .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            var next = AppAudioEQ.normalized(gains)
            next[index] = min(12, max(-12, band(index) + step))
            onChange(next)
          }
        }
      }
    }
    .padding(.leading, 46)
    .padding(.top, 4)
  }

  private func band(_ index: Int) -> Double {
    gains.indices.contains(index) ? gains[index] : 0
  }

  private func decibelText(_ value: Double) -> String {
    abs(value) < 0.05 ? "0" : String(format: "%+.0f", value)
  }

  private func frequencyLabel(_ frequency: Double) -> String {
    if frequency >= 1000 {
      return "\(Int(frequency / 1000))k"
    }
    return "\(Int(frequency))"
  }
}

private struct EqualizerBandSlider: View {
  @Binding var value: Double

  var body: some View {
    GeometryReader { proxy in
      let height = max(proxy.size.height, 1)
      let fraction = (min(12, max(-12, value)) + 12) / 24
      let knobY = height * (1 - fraction)
      ZStack {
        Capsule()
          .fill(Color.primary.opacity(0.14))
          .frame(width: 4)
        Rectangle()
          .fill(Color.primary.opacity(0.28))
          .frame(width: 10, height: 1)
          .position(x: proxy.size.width / 2, y: height / 2)
        Circle()
          .fill(Color.accentColor)
          .frame(width: 16, height: 16)
          .position(x: proxy.size.width / 2, y: knobY)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            let y = min(max(0, gesture.location.y), height)
            value = min(12, max(-12, 12 - (y / height) * 24))
          }
      )
    }
  }
}
