import AudioToolbox
import CoreAudio
import Foundation

struct SystemOutputState: Equatable, Sendable {
  var deviceName: String
  var deviceUID: String?
  var volume: Double
  var isMuted: Bool
  var canChangeVolume: Bool

  static let unknown = SystemOutputState(
    deviceName: "",
    deviceUID: nil,
    volume: 1,
    isMuted: false,
    canChangeVolume: false
  )
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
  var objectID: AudioObjectID
  var uid: String
  var name: String
  var transport: UInt32
  var volume: Double = 1
  var isMuted: Bool = false
  var canChangeVolume: Bool = false

  var id: String { uid }
}

enum AppAudioDeviceSymbol {
  static func systemImage(name: String, transport: UInt32) -> String {
    if name.localizedCaseInsensitiveContains("airpod") {
      return "airpods"
    }
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn:
      if name.localizedCaseInsensitiveContains("macbook")
        || name.localizedCaseInsensitiveContains("laptop")
      {
        return "laptopcomputer"
      }
      return "speaker.wave.2"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      return "headphones"
    case kAudioDeviceTransportTypeAirPlay,
      kAudioDeviceTransportTypeRemoteStreaming,
      kAudioDeviceTransportTypeRemoteScreen:
      return "airplayaudio"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
      return "display"
    case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
      return "cable.connector"
    default:
      return "speaker.wave.2"
    }
  }
}

protocol SystemOutputControlling: AnyObject {
  func read() -> SystemOutputState
  func outputDevices() -> [AudioOutputDevice]
  func setDefaultDevice(uid: String)
  func setVolume(_ volume: Float)
  func setVolume(_ volume: Float, deviceUID: String)
  func setMuted(_ muted: Bool)
  func setMuted(_ muted: Bool, deviceUID: String)
  func observe(_ handler: @escaping @Sendable () -> Void)
  func readInput() -> SystemOutputState
  func inputDevices() -> [AudioOutputDevice]
  func setDefaultInputDevice(uid: String)
  func setInputVolume(_ volume: Float, deviceUID: String)
  func setInputMuted(_ muted: Bool, deviceUID: String)
}

extension SystemOutputControlling {
  func setVolume(_ volume: Float, deviceUID: String) {}
  func setMuted(_ muted: Bool, deviceUID: String) {}
  func readInput() -> SystemOutputState { .unknown }
  func inputDevices() -> [AudioOutputDevice] { [] }
  func setDefaultInputDevice(uid: String) {}
  func setInputVolume(_ volume: Float, deviceUID: String) {}
  func setInputMuted(_ muted: Bool, deviceUID: String) {}
}

final class SystemOutputControl: SystemOutputControlling, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.shenmuoso.macscope.output-volume")
  private var deviceListener: AudioObjectPropertyListenerBlock?

  func read() -> SystemOutputState {
    guard let deviceID = defaultOutputDevice() else { return .unknown }
    return state(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  func outputDevices() -> [AudioOutputDevice] {
    devices(scope: kAudioDevicePropertyScopeOutput)
  }

  func inputDevices() -> [AudioOutputDevice] {
    devices(scope: kAudioDevicePropertyScopeInput)
  }

  func readInput() -> SystemOutputState {
    guard let deviceID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return .unknown }
    return state(for: deviceID, scope: kAudioDevicePropertyScopeInput)
  }

  func setDefaultDevice(uid: String) {
    setDefaultDevice(uid, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioDevicePropertyScopeOutput)
  }

  func setDefaultInputDevice(uid: String) {
    setDefaultDevice(uid, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioDevicePropertyScopeInput)
  }

  func setVolume(_ volume: Float) {
    guard let deviceID = defaultOutputDevice() else { return }
    setVolume(volume, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  func setVolume(_ volume: Float, deviceUID: String) {
    guard let deviceID = deviceID(forUID: deviceUID, scope: kAudioDevicePropertyScopeOutput) else { return }
    setVolume(volume, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  func setInputVolume(_ volume: Float, deviceUID: String) {
    guard let deviceID = deviceID(forUID: deviceUID, scope: kAudioDevicePropertyScopeInput) else { return }
    setVolume(volume, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
  }

  func setMuted(_ muted: Bool) {
    guard let deviceID = defaultOutputDevice() else { return }
    setMuted(muted, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  func setMuted(_ muted: Bool, deviceUID: String) {
    guard let deviceID = deviceID(forUID: deviceUID, scope: kAudioDevicePropertyScopeOutput) else { return }
    setMuted(muted, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  func setInputMuted(_ muted: Bool, deviceUID: String) {
    guard let deviceID = deviceID(forUID: deviceUID, scope: kAudioDevicePropertyScopeInput) else { return }
    setMuted(muted, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
  }

  func observe(_ handler: @escaping @Sendable () -> Void) {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      handler()
    }
    deviceListener = block
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      queue,
      block
    )
  }

  private func defaultOutputDevice() -> AudioObjectID? {
    defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
  }

  private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    let deviceID: AudioObjectID? = CoreAudioProperty.value(
      selector,
      objectID: AudioObjectID(kAudioObjectSystemObject)
    )
    guard let deviceID, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private func devices(scope: AudioObjectPropertyScope) -> [AudioOutputDevice] {
    CoreAudioProperty.objectIDs(kAudioHardwarePropertyDevices).compactMap { deviceID in
      let streams = CoreAudioProperty.objectIDs(
        kAudioDevicePropertyStreams,
        objectID: deviceID,
        scope: scope
      )
      guard !streams.isEmpty else { return nil }
      guard let uid = CoreAudioProperty.string(kAudioDevicePropertyDeviceUID, objectID: deviceID),
        !uid.isEmpty
      else { return nil }
      let name = CoreAudioProperty.string(kAudioObjectPropertyName, objectID: deviceID) ?? uid
      let transport: UInt32 =
        CoreAudioProperty.value(kAudioDevicePropertyTransportType, objectID: deviceID) ?? 0
      if transport == kAudioDeviceTransportTypeAggregate || name == "MacScope" {
        return nil
      }
      let levels = state(for: deviceID, scope: scope)
      return AudioOutputDevice(
        objectID: deviceID,
        uid: uid,
        name: name,
        transport: transport,
        volume: levels.volume,
        isMuted: levels.isMuted,
        canChangeVolume: levels.canChangeVolume
      )
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func state(for deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> SystemOutputState {
    let name = CoreAudioProperty.string(kAudioObjectPropertyName, objectID: deviceID) ?? ""
    let uid = CoreAudioProperty.string(kAudioDevicePropertyDeviceUID, objectID: deviceID)
    let volumeSelector = volumeSelector(for: deviceID, scope: scope)
    let canChange = volumeSelector.map {
      CoreAudioProperty.isSettable($0, objectID: deviceID, scope: scope)
    } ?? false
    let volume = volumeSelector.flatMap {
      CoreAudioProperty.value($0, objectID: deviceID, scope: scope) as Float32?
    }
    let muted: UInt32? = CoreAudioProperty.value(
      kAudioDevicePropertyMute,
      objectID: deviceID,
      scope: scope
    )
    return SystemOutputState(
      deviceName: name,
      deviceUID: uid,
      volume: Double(min(1, max(0, volume ?? 1))),
      isMuted: (muted ?? 0) != 0,
      canChangeVolume: canChange
    )
  }

  private func deviceID(forUID uid: String, scope: AudioObjectPropertyScope) -> AudioObjectID? {
    devices(scope: scope).first { $0.uid == uid }?.objectID
  }

  private func setDefaultDevice(
    _ uid: String,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) {
    guard let deviceID = deviceID(forUID: uid, scope: scope) else { return }
    _ = CoreAudioProperty.set(
      UInt32(deviceID),
      selector: selector,
      objectID: AudioObjectID(kAudioObjectSystemObject)
    )
  }

  private func setVolume(_ volume: Float, deviceID: AudioObjectID, scope: AudioObjectPropertyScope) {
    guard let selector = volumeSelector(for: deviceID, scope: scope) else { return }
    let clamped = min(1, max(0, volume))
    _ = CoreAudioProperty.set(clamped, selector: selector, objectID: deviceID, scope: scope)
  }

  private func setMuted(_ muted: Bool, deviceID: AudioObjectID, scope: AudioObjectPropertyScope) {
    guard CoreAudioProperty.isSettable(kAudioDevicePropertyMute, objectID: deviceID, scope: scope) else { return }
    _ = CoreAudioProperty.set(
      UInt32(muted ? 1 : 0),
      selector: kAudioDevicePropertyMute,
      objectID: deviceID,
      scope: scope
    )
  }

  private func volumeSelector(
    for deviceID: AudioObjectID,
    scope: AudioObjectPropertyScope
  ) -> AudioObjectPropertySelector? {
    if CoreAudioProperty.has(
      kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      objectID: deviceID,
      scope: scope
    ) {
      return kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    }
    if CoreAudioProperty.has(kAudioDevicePropertyVolumeScalar, objectID: deviceID, scope: scope) {
      return kAudioDevicePropertyVolumeScalar
    }
    return nil
  }
}
