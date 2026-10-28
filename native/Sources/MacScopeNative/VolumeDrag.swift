import CoreAudio
import Foundation

/// Hardware volume writes that a slider can call without entering the main actor.
final class HardwareVolumeRouter: @unchecked Sendable {
  private let control: any SystemOutputControlling

  init(_ control: any SystemOutputControlling) {
    self.control = control
  }

  func setVolume(_ volume: Double, deviceID: AudioObjectID, input: Bool) {
    guard deviceID != kAudioObjectUnknown else { return }
    let scope: AudioObjectPropertyScope = input
      ? kAudioDevicePropertyScopeInput
      : kAudioDevicePropertyScopeOutput
    control.setVolume(
      Float(min(1, max(0, volume))),
      deviceID: deviceID,
      scope: scope
    )
  }
}

/// App gain writes. The playback tap reference is updated when taps start and stop.
final class AppGainRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var taps: [String: any AppAudioTap] = [:]
  private var boosts: [String: Double] = [:]
  private var muted: [String: Bool] = [:]
  private var latest: [String: Double] = [:]

  func replace(_ playback: [String: any AppAudioTap], levels: [String: AppAudioLevel]) {
    lock.lock()
    taps = playback
    boosts = levels.mapValues(\.boost)
    muted = levels.mapValues(\.isMuted)
    lock.unlock()
  }

  func takeLatest() -> [String: Double] {
    lock.lock()
    let values = latest
    latest.removeAll()
    lock.unlock()
    return values
  }

  func setGain(key: String, volume: Double) {
    lock.lock()
    latest[key] = volume
    let tap = taps[key]
    let boost = boosts[key] ?? 1
    let isMuted = muted[key] ?? false
    lock.unlock()
    guard let tap, tap.isRunning, !tap.rendersSilence else { return }
    let gain = isMuted ? Float(0) : Float(min(1, max(0, volume)) * boost)
    tap.setGain(gain)
  }
}
