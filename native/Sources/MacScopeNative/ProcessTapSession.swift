import AudioToolbox
import CoreAudio
import Foundation
import os

enum AppAudioTapError: Error {
  case unsupported
  case format
  case coreAudio(OSStatus)
}

protocol AppAudioTap: AnyObject, Sendable {
  var processObjectIDs: [AudioObjectID] { get }
  var outputDeviceUIDs: [String] { get }
  var rendersSilence: Bool { get }
  var isRunning: Bool { get }
  func start(processObjectIDs: [AudioObjectID], outputDeviceUIDs: [String], rendersSilence: Bool) throws
  func setGain(_ gain: Float)
  func setEQ(_ gains: [Double])
  func consumePeaks() -> (left: Float, right: Float)
  func stop()
}

@available(macOS 14.2, *)
final class ProcessTapSession: AppAudioTap, @unchecked Sendable {
  private let gain = OSAllocatedUnfairLock(initialState: Float(1))
  private let peaks = OSAllocatedUnfairLock(initialState: (left: Float(0), right: Float(0)))
  private let equalizer = AppAudioEQProcessor()
  private let state = OSAllocatedUnfairLock(initialState: SessionState())
  private let queue: DispatchQueue

  init(key: String) {
    queue = DispatchQueue(label: "com.shenmuoso.macscope.app-audio.\(key)", qos: .userInteractive)
  }

  var processObjectIDs: [AudioObjectID] {
    state.withLock { $0.processObjectIDs }
  }

  var outputDeviceUIDs: [String] {
    state.withLock { $0.outputDeviceUIDs }
  }

  var rendersSilence: Bool {
    state.withLock { $0.rendersSilence }
  }

  var isRunning: Bool {
    state.withLock { $0.aggregateID != kAudioObjectUnknown }
  }

  func setGain(_ gain: Float) {
    self.gain.withLock { $0 = gain }
  }

  func setEQ(_ gains: [Double]) {
    equalizer.setGains(gains)
  }

  func consumePeaks() -> (left: Float, right: Float) {
    peaks.withLock { current in
      let value = current
      current = (0, 0)
      return value
    }
  }

  func start(processObjectIDs: [AudioObjectID], outputDeviceUIDs: [String], rendersSilence: Bool) throws {
    stop()
    guard !processObjectIDs.isEmpty, !outputDeviceUIDs.isEmpty else { throw AppAudioTapError.unsupported }

    let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
    description.uuid = UUID()
    description.name = "MacScope"
    description.muteBehavior = rendersSilence ? CATapMuteBehavior.unmuted : CATapMuteBehavior.mutedWhenTapped
    description.isPrivate = true

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
      throw AppAudioTapError.coreAudio(tapStatus)
    }

    let aggregateUID = UUID().uuidString
    // Do not set channels-out. A forced channel count makes a Bluetooth aggregate
    // keep playing through the built-in speakers.
    let subdevices: [[String: Any]] = outputDeviceUIDs.enumerated().map { index, uid in
      var entry: [String: Any] = [
        kAudioSubDeviceUIDKey: uid,
      ]
      if index > 0 {
        entry[kAudioSubDeviceDriftCompensationKey] = 1 as NSNumber
      }
      return entry
    }
    let composition: [String: Any] = [
      kAudioAggregateDeviceNameKey: "MacScope",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUIDs[0],
      kAudioAggregateDeviceIsPrivateKey: 1 as NSNumber,
      kAudioAggregateDeviceIsStackedKey: 0 as NSNumber,
      kAudioAggregateDeviceTapAutoStartKey: 0 as NSNumber,
      kAudioAggregateDeviceSubDeviceListKey: subdevices,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: description.uuid.uuidString,
          kAudioSubTapDriftCompensationKey: 1 as NSNumber,
        ]
      ],
    ]

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
    guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
      AudioHardwareDestroyProcessTap(tapID)
      throw AppAudioTapError.coreAudio(aggregateStatus)
    }
    matchSampleRate(of: aggregateID, toFirstDeviceIn: outputDeviceUIDs)

    guard let inputFormat = streamFormat(aggregateID, scope: kAudioObjectPropertyScopeInput),
      let outputFormat = streamFormat(aggregateID, scope: kAudioObjectPropertyScopeOutput),
      inputFormat.isFloat32,
      outputFormat.isFloat32
    else {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      AudioHardwareDestroyProcessTap(tapID)
      throw AppAudioTapError.format
    }

    var procID: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
      [weak self] _, input, _, output, _ in
      guard let self else { return }
      let gain = self.gain.withLock { $0 }
      let formats = self.state.withLock { ($0.inputFormat, $0.outputFormat, $0.rendersSilence) }
      guard let inputFormat = formats.0, let outputFormat = formats.1 else { return }
      let level = AppAudioGain.peaks(input: input, format: inputFormat)
      self.peaks.withLock { current in
        current.left = max(current.left, level.left)
        current.right = max(current.right, level.right)
      }
      let playbackGain: Float = formats.2 ? 0 : gain
      AppAudioGain.render(
        input: input,
        inputFormat: inputFormat,
        output: output,
        outputFormat: outputFormat,
        gain: playbackGain,
        effect: formats.2 ? nil : self.equalizer
      )
    }
    guard procStatus == noErr, let procID else {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      AudioHardwareDestroyProcessTap(tapID)
      throw AppAudioTapError.coreAudio(procStatus)
    }

    let createdTapID = tapID
    let createdAggregateID = aggregateID
    state.withLock {
      $0.tapID = createdTapID
      $0.aggregateID = createdAggregateID
      $0.procID = procID
      $0.outputDeviceUIDs = outputDeviceUIDs
      $0.rendersSilence = rendersSilence
      $0.processObjectIDs = processObjectIDs
      $0.inputFormat = inputFormat
      $0.outputFormat = outputFormat
    }

    let startStatus = AudioDeviceStart(aggregateID, procID)
    guard startStatus == noErr else {
      stop()
      throw AppAudioTapError.coreAudio(startStatus)
    }
    let active = activeSubdeviceUIDs(aggregateID)
    if !active.isEmpty, Set(active).isDisjoint(with: outputDeviceUIDs) {
      stop()
      throw AppAudioTapError.coreAudio(kAudioHardwareBadDeviceError)
    }
  }

  func stop() {
    let snapshot = state.withLock { state -> SessionState in
      let snapshot = state
      state = SessionState()
      return snapshot
    }
    if snapshot.aggregateID != kAudioObjectUnknown {
      if let procID = snapshot.procID {
        AudioDeviceStop(snapshot.aggregateID, procID)
        AudioDeviceDestroyIOProcID(snapshot.aggregateID, procID)
      }
      AudioHardwareDestroyAggregateDevice(snapshot.aggregateID)
    }
    if snapshot.tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(snapshot.tapID)
    }
  }

  private func streamFormat(
    _ deviceID: AudioObjectID,
    scope: AudioObjectPropertyScope
  ) -> AudioRenderFormat? {
    let description: AudioStreamBasicDescription? = CoreAudioProperty.value(
      kAudioDevicePropertyStreamFormat,
      objectID: deviceID,
      scope: scope
    )
    return description.map(AudioRenderFormat.make)
  }

  private func matchSampleRate(of aggregateID: AudioObjectID, toFirstDeviceIn uids: [String]) {
    guard let uid = uids.first, let deviceID = deviceID(forUID: uid) else { return }
    let rate: Float64? = CoreAudioProperty.value(
      kAudioDevicePropertyNominalSampleRate,
      objectID: deviceID
    )
    guard let rate, rate > 0 else { return }
    _ = CoreAudioProperty.set(
      rate,
      selector: kAudioDevicePropertyNominalSampleRate,
      objectID: aggregateID
    )
  }

  private func activeSubdeviceUIDs(_ aggregateID: AudioObjectID) -> [String] {
    CoreAudioProperty.objectIDs(
      kAudioAggregateDevicePropertyActiveSubDeviceList,
      objectID: aggregateID
    ).compactMap { CoreAudioProperty.string(kAudioDevicePropertyDeviceUID, objectID: $0) }
  }

  private func deviceID(forUID uid: String) -> AudioObjectID? {
    CoreAudioProperty.objectIDs(kAudioHardwarePropertyDevices).first { deviceID in
      CoreAudioProperty.string(kAudioDevicePropertyDeviceUID, objectID: deviceID) == uid
    }
  }
}

@available(macOS 14.2, *)
private struct SessionState {
  var tapID: AudioObjectID = kAudioObjectUnknown
  var aggregateID: AudioObjectID = kAudioObjectUnknown
  var procID: AudioDeviceIOProcID?
  var outputDeviceUIDs: [String] = []
  var rendersSilence = false
  var processObjectIDs: [AudioObjectID] = []
  var inputFormat: AudioRenderFormat?
  var outputFormat: AudioRenderFormat?
}

enum AppAudioTapFactory {
  static func live(key: String) -> any AppAudioTap {
    if #available(macOS 14.2, *) {
      return ProcessTapSession(key: key)
    }
    return DisabledAppAudioTap()
  }
}

final class DisabledAppAudioTap: AppAudioTap, @unchecked Sendable {
  let processObjectIDs: [AudioObjectID] = []
  let outputDeviceUIDs: [String] = []
  let rendersSilence = false
  let isRunning = false

  func start(processObjectIDs: [AudioObjectID], outputDeviceUIDs: [String], rendersSilence: Bool) throws {
    throw AppAudioTapError.unsupported
  }

  func setGain(_ gain: Float) {}
  func setEQ(_ gains: [Double]) {}
  func consumePeaks() -> (left: Float, right: Float) { (0, 0) }

  func stop() {}
}
