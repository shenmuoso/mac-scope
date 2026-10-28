import CoreAudio
import Foundation

struct AppAudioMeter: Equatable {
  var left: Double
  var right: Double

  static let silent = AppAudioMeter(left: 0, right: 0)

  /// Maps a linear peak into a meter height. Speech often sits near -20 dB, which is only a sliver on a linear bar.
  static func visual(_ peak: Double) -> Double {
    let amplitude = min(1, max(0, peak))
    guard amplitude > 0.000_1 else { return 0 }
    let decibels = 20 * log10(amplitude)
    return min(1, max(0, (decibels + 40) / 40))
  }
}

/// Meter levels publish on their own object so a level tick does not rebuild the volume sliders.
@MainActor
final class AppAudioMeters: ObservableObject {
  @Published private(set) var values: [String: AppAudioMeter] = [:]

  fileprivate func update(_ values: [String: AppAudioMeter]) {
    guard values != self.values else { return }
    self.values = values
  }
}

struct AppAudioRow: Identifiable, Equatable {
  var key: String
  var name: String
  var bundlePath: String?
  var level: AppAudioLevel
  var isPlaying: Bool
  var processes: [AudioProcessSnapshot]

  var id: String { key }
}

@MainActor
final class AppAudioController: ObservableObject {
  @Published private(set) var output = SystemOutputState.unknown
  @Published private(set) var outputDevices: [AudioOutputDevice] = []
  @Published private(set) var input = SystemOutputState.unknown
  @Published private(set) var inputDevices: [AudioOutputDevice] = []
  @Published private(set) var apps: [AppAudioRow] = []
  @Published private(set) var perAppErrorKey: String?
  @Published private(set) var lastTapStatus: Int32?
  let levelMeters = AppAudioMeters()

  private var levels: [String: AppAudioLevel]
  private var liveLevels: [String: AppAudioLevel] = [:]
  private var taps: [String: any AppAudioTap] = [:]
  private var meterTaps: [String: any AppAudioTap] = [:]
  private var displayedMeters: [String: AppAudioMeter] = [:]
  private var retryAfter: [String: Date] = [:]
  private var monitor: Task<Void, Never>?
  private var meterMonitor: Task<Void, Never>?
  private var isEditingOutput = false
  private var isEditingAppVolume = false
  private var pendingLevelSave = false
  private var pendingOutputUID: String?
  private var pendingOutputPreviousUID: String?
  private var liveOutputVolume: Double?
  private var liveDeviceVolumes: [DeviceVolumeKey: Double] = [:]
  private var devicePins: [DeviceVolumeKey: VolumePin] = [:]
  private var outputPin: VolumePin?
  private var volumeEnsureInFlight: Set<String> = []
  private var volumeEditGeneration = 0
  private var volumeDrags = 0
  private var editingDeviceUID: String?
  private let defaults: UserDefaults
  private let processes: any AppAudioProcessListing
  private let outputControl: any SystemOutputControlling
  nonisolated let hardwareVolumes: HardwareVolumeRouter
  nonisolated let appGains: AppGainRouter
  private let makeTap: (String) -> any AppAudioTap
  private let excludedPIDs: Set<pid_t>
  private let excludedBundleIDs: Set<String>

  init(
    defaults: UserDefaults = .standard,
    processes: any AppAudioProcessListing = CoreAudioAppProcessList(),
    outputControl: any SystemOutputControlling = SystemOutputControl(),
    makeTap: @escaping (String) -> any AppAudioTap = AppAudioTapFactory.live,
    excludedPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier],
    excludedBundleIDs: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
  ) {
    self.defaults = defaults
    self.processes = processes
    self.outputControl = outputControl
    self.hardwareVolumes = HardwareVolumeRouter(outputControl)
    self.appGains = AppGainRouter()
    self.makeTap = makeTap
    self.excludedPIDs = excludedPIDs
    self.excludedBundleIDs = Set(excludedBundleIDs)
    levels = AppAudioLevelStore.load(from: defaults)
  }

  func start() {
    guard monitor == nil else { return }
    refreshOutput(restartTaps: false)
    outputControl.observe { [weak self] in
      Task { @MainActor in
        guard let self, self.volumeDrags == 0 else { return }
        self.refreshOutput(restartTaps: true)
      }
    }
    reconcile()
    monitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let self, !Task.isCancelled, self.volumeDrags == 0 else { continue }
        let poll = await self.pollAudio()
        guard !Task.isCancelled, self.volumeDrags == 0 else { continue }
        self.refreshOutput(restartTaps: false, poll: poll)
        if !self.isEditingAppVolume {
          self.reconcile(refreshDevices: false)
        }
      }
    }
    meterMonitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 33_000_000)
        guard let self, !Task.isCancelled, self.volumeDrags == 0 else { continue }
        self.publishMeters()
      }
    }
  }

  func prepareForSleep() {
    stopAllTaps()
  }

  func resumeAfterWake() {
    reconcile()
  }

  func prepareForApplicationExit() {
    absorbDraggedAppVolumes()
    endAppVolumeEdit()
    volumeEditGeneration += 1
    outputControl.flushVolumeWrites()
    monitor?.cancel()
    monitor = nil
    meterMonitor?.cancel()
    meterMonitor = nil
    stopAllTaps()
  }

  func setOutputEditing(_ isEditing: Bool) {
    isEditingOutput = isEditing
    if !isEditing {
      if let liveOutputVolume {
        // The hardware write is already queued. Remember the value so a later read cannot jump backward.
        output.volume = liveOutputVolume
        outputPin = VolumePin(volume: liveOutputVolume, until: Date().addingTimeInterval(1.5))
        self.liveOutputVolume = nil
      }
    }
  }

  func setOutputVolume(_ volume: Double) {
    let clamped = min(1, max(0, volume))
    output.volume = clamped
    outputControl.setVolume(Float(clamped))
  }

  /// Drag ticks must not publish `output` or wait on the hardware write.
  func setLiveOutputVolume(_ volume: Double) {
    let clamped = min(1, max(0, volume))
    liveOutputVolume = clamped
    outputControl.setVolume(Float(clamped))
  }

  func setOutputMuted(_ isMuted: Bool) {
    output.isMuted = isMuted
    outputControl.setMuted(isMuted)
  }

  func setDefaultOutputDevice(_ uid: String) {
    guard !uid.isEmpty else { return }
    // Bluetooth output often reports the previous device for a moment after the switch.
    // Keep the device the user chose until Core Audio catches up, and rebuild taps onto it.
    if outputDevices.contains(where: { $0.uid == uid }) {
      pendingOutputPreviousUID = output.deviceUID
      pendingOutputUID = uid
    }
    let objectID = outputDevices.first(where: { $0.uid == uid })?.objectID ?? kAudioObjectUnknown
    outputControl.setDefaultDevice(uid: uid, objectID: objectID)
    retryAfter.removeAll()
    refreshOutput(restartTaps: false)
    reconcile()
    // A tap aggregate on the previous device can keep that device as the audible output.
    // Set the default again after those taps have moved.
    outputControl.setDefaultDevice(uid: uid, objectID: objectID)
    refreshOutput(restartTaps: false)
  }

  func setDefaultInputDevice(_ uid: String) {
    guard !uid.isEmpty else { return }
    outputControl.setDefaultInputDevice(uid: uid)
    refreshOutput(restartTaps: false)
  }

  func setDeviceEditing(_ uid: String?) {
    if let uid {
      editingDeviceUID = uid
      return
    }
    commitLiveDeviceVolumes()
    editingDeviceUID = nil
  }

  /// Hardware volume changes are applied without republishing the device list on every slider tick.
  func setLiveDeviceVolume(_ volume: Double, uid: String, input: Bool) {
    let clamped = min(1, max(0, volume))
    liveDeviceVolumes[DeviceVolumeKey(uid: uid, input: input)] = clamped
    writeDeviceVolume(clamped, uid: uid, input: input)
  }

  func setDeviceVolume(_ volume: Double, uid: String, input: Bool) {
    let clamped = min(1, max(0, volume))
    updateDevice(uid, input: input) { device in
      device.volume = clamped
    }
    writeDeviceVolume(clamped, uid: uid, input: input)
    if !input, output.deviceUID == uid {
      output.volume = clamped
    }
  }

  func setDeviceMuted(_ isMuted: Bool, uid: String, input: Bool) {
    updateDevice(uid, input: input) { device in
      device.isMuted = isMuted
    }
    if input {
      outputControl.setInputMuted(isMuted, deviceUID: uid)
    } else {
      outputControl.setMuted(isMuted, deviceUID: uid)
      if output.deviceUID == uid {
        output.isMuted = isMuted
      }
    }
  }

  func setAppOutputDevices(_ uids: [String], for key: String) {
    var level = level(for: key)
    level.outputDeviceUIDs = uids.filter { uid in outputDevices.contains { $0.uid == uid } }
    if level.outputDeviceUIDs.count < 2 {
      level.routesToMultipleDevices = false
    }
    store(level, for: key)
    syncTap(for: key)
  }

  func setMultipleRoutes(_ enabled: Bool, for key: String) {
    var level = level(for: key)
    level.routesToMultipleDevices = enabled
    if enabled && level.outputDeviceUIDs.isEmpty, let system = output.deviceUID {
      level.outputDeviceUIDs = [system]
    }
    if !enabled, level.outputDeviceUIDs.count > 1 {
      level.outputDeviceUIDs = Array(level.outputDeviceUIDs.prefix(1))
    }
    store(level, for: key)
    syncTap(for: key)
  }

  func toggleAppOutputDevice(_ uid: String, for key: String) {
    guard outputDevices.contains(where: { $0.uid == uid }) else { return }
    var level = level(for: key)
    level.routesToMultipleDevices = true
    if let index = level.outputDeviceUIDs.firstIndex(of: uid) {
      level.outputDeviceUIDs.remove(at: index)
    } else {
      level.outputDeviceUIDs.append(uid)
    }
    store(level, for: key)
    syncTap(for: key)
  }

  func setBoost(_ boost: Double, for key: String) {
    var level = level(for: key)
    level.boost = boost
    applyLevel(level, for: key)
  }

  func setEQ(_ gains: [Double], for key: String) {
    var level = level(for: key)
    level.eqGains = gains
    store(level, for: key)
    if let tap = taps[key], tap.isRunning, !tap.rendersSilence {
      tap.setEQ(level.eqGains)
      tap.setGain(AppAudioRoute.gain(for: level))
    } else {
      syncTap(for: key)
    }
  }

  func setVolume(_ volume: Double, for key: String) {
    var level = level(for: key)
    level.volume = min(1, max(0, volume))
    applyLevel(level, for: key)
  }

  func beginAppVolumeEdit() {
    isEditingAppVolume = true
  }

  /// Writes a volume that was only applied to the running tap, so quitting mid-drag still remembers it.
  private func absorbDraggedAppVolumes() {
    let dragged = appGains.takeLatest()
    guard !dragged.isEmpty else { return }
    for (key, volume) in dragged {
      var level = level(for: key)
      level.volume = min(1, max(0, volume))
      let updated = level.clamped
      if AppAudioRoute.needsTap(updated) || updated.routesToMultipleDevices {
        levels[key] = updated
      } else {
        levels[key] = nil
      }
    }
    AppAudioLevelStore.save(levels, to: defaults)
  }

  /// Counts an in-progress slider gesture. While it is non-zero the main thread
  /// does not read Core Audio or publish meters.
  func beginVolumeDrag() {
    volumeDrags += 1
  }

  /// Records the released device volume without republishing the audio page.
  func endDeviceVolumeDrag(uid: String, input: Bool, volume: Double) {
    let clamped = min(1, max(0, volume))
    let until = Date().addingTimeInterval(1.5)
    devicePins[DeviceVolumeKey(uid: uid, input: input)] = VolumePin(volume: clamped, until: until)
    if !input, output.deviceUID == uid {
      outputPin = VolumePin(volume: clamped, until: until)
      liveOutputVolume = nil
    }
    if editingDeviceUID == uid { editingDeviceUID = nil }
    releaseVolumeDragGate()
  }

  /// Saves the released app volume. A tap is started or stopped after the gesture, and only when needed.
  func finishAppVolumeDrag(key: String, volume: Double) {
    var level = level(for: key)
    level.volume = min(1, max(0, volume))
    let updated = level.clamped
    if AppAudioRoute.needsTap(updated) || updated.routesToMultipleDevices {
      levels[key] = updated
    } else {
      levels[key] = nil
    }
    let needs = AppAudioRoute.needsTap(updated, systemDeviceUID: output.deviceUID)
    let playing = taps[key]?.isRunning == true && taps[key]?.rendersSilence == false
    let generation = volumeEditGeneration
    releaseVolumeDragGate {
      AppAudioLevelStore.save(self.levels, to: self.defaults)
      guard generation == self.volumeEditGeneration, needs != playing else { return }
      self.reconcile()
    }
  }

  /// Keeps device reads and meter publishes paused until mouse-up has finished drawing.
  private func releaseVolumeDragGate(then followUp: (@MainActor () -> Void)? = nil) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 200_000_000)
      self.volumeDrags = max(0, self.volumeDrags - 1)
      guard self.volumeDrags == 0 else { return }
      followUp?()
    }
  }

  /// Slider ticks update the running tap only. Publishing the app list or saving preferences here stalls the drag.
  func setInteractiveVolume(_ volume: Double, for key: String) {
    isEditingAppVolume = true
    var level = level(for: key)
    level.volume = min(1, max(0, volume))
    let updated = level.clamped
    liveLevels[key] = updated
    if AppAudioRoute.needsTap(updated) || updated.routesToMultipleDevices {
      levels[key] = updated
    } else {
      levels[key] = nil
    }
    pendingLevelSave = true
    if let tap = taps[key], tap.isRunning, !tap.rendersSilence {
      tap.setGain(AppAudioRoute.gain(for: updated))
      return
    }
    if let retry = retryAfter[key], retry > Date() {
      return
    }
    // Starting a process tap is slow. Do it once per drag, not on every tick.
    guard volumeEnsureInFlight.insert(key).inserted else { return }
    reconcile()
    volumeEnsureInFlight.remove(key)
    if let tap = taps[key], tap.isRunning, !tap.rendersSilence {
      tap.setGain(AppAudioRoute.gain(for: updated))
    }
  }

  func endAppVolumeEdit() {
    guard isEditingAppVolume else { return }
    isEditingAppVolume = false
    let pending = liveLevels
    liveLevels.removeAll()
    let shouldReconcile = pending.contains { key, level in
      let needs = AppAudioRoute.needsTap(level, systemDeviceUID: output.deviceUID)
      let playing = taps[key]?.isRunning == true && taps[key]?.rendersSilence == false
      return needs != playing
    }
    if pendingLevelSave {
      pendingLevelSave = false
      AppAudioLevelStore.save(levels, to: defaults)
    }
    var next = apps
    var changed = false
    for (key, level) in pending {
      guard let index = next.firstIndex(where: { $0.key == key }), next[index].level != level else { continue }
      next[index].level = level
      changed = true
    }
    if changed { apps = next }
    guard shouldReconcile else { return }
    // Stopping or starting a tap waits on Core Audio. Do it after the mouse-up handler returns.
    let generation = volumeEditGeneration
    Task { @MainActor in
      guard generation == self.volumeEditGeneration else { return }
      self.reconcile()
    }
  }

  func setMuted(_ isMuted: Bool, for key: String) {
    var level = level(for: key)
    level.isMuted = isMuted
    applyLevel(level, for: key)
  }

  func reconcile(refreshDevices: Bool = true) {
    if refreshDevices {
      refreshOutput(restartTaps: false)
    }
    normalizeDevicePins()
    let groups = AppAudioCatalog.groups(
      processes: processes.outputProcesses(),
      levels: levels,
      excludedPIDs: excludedPIDs,
      excludedBundleIDs: excludedBundleIDs
    )
    let nextApps = groups.map(row(for:)).sorted(by: sortRows)
    if nextApps != apps { apps = nextApps }
    guard AppAudioRoute.isPerAppSupported else {
      stopAllTaps()
      return
    }
    guard let deviceUID = output.deviceUID, !deviceUID.isEmpty else {
      stopAllTaps()
      return
    }

    var playback: Set<String> = []
    var metering: Set<String> = []
    var failed = false
    var status: Int32?
    for row in apps where !row.processes.isEmpty {
      if AppAudioRoute.needsTap(row.level, systemDeviceUID: deviceUID) {
        playback.insert(row.key)
        stopMeter(for: row.key)
        switch ensureTap(
          for: row,
          deviceUIDs: targetDeviceUIDs(for: row),
          rendersSilence: false,
          into: &taps
        ) {
        case .running:
          break
        case .failed(let code):
          failed = true
          status = code
        case .waiting:
          failed = true
        }
      } else {
        metering.insert(row.key)
        stopPlayback(for: row.key)
        switch ensureTap(
          for: row,
          deviceUIDs: [deviceUID],
          rendersSilence: true,
          into: &meterTaps
        ) {
        case .running:
          break
        case .failed(let code):
          failed = true
          status = code
        case .waiting:
          failed = true
        }
      }
    }
    for key in taps.keys where !playback.contains(key) {
      stopPlayback(for: key)
    }
    for key in meterTaps.keys where !metering.contains(key) {
      stopMeter(for: key)
    }
    let errorKey = failed ? "MacScope could not adjust one or more application volumes." : nil
    if perAppErrorKey != errorKey { perAppErrorKey = errorKey }
    if let status {
      if lastTapStatus != status { lastTapStatus = status }
    } else if !failed, lastTapStatus != nil {
      lastTapStatus = nil
    }
    syncAppGainRouter()
  }

  private struct AudioPoll: Sendable {
    var outputDevices: [AudioOutputDevice]
    var inputDevices: [AudioOutputDevice]
    var output: SystemOutputState
    var input: SystemOutputState
  }

  private func pollAudio() async -> AudioPoll {
    let control = outputControl
    return await Task.detached {
      AudioPoll(
        outputDevices: control.outputDevices(),
        inputDevices: control.inputDevices(),
        output: control.read(),
        input: control.readInput()
      )
    }.value
  }

  private func refreshOutput(restartTaps: Bool, poll: AudioPoll? = nil) {
    let latestDevices = preservingEdit(poll?.outputDevices ?? outputControl.outputDevices(), input: false)
    if latestDevices != outputDevices { outputDevices = latestDevices }
    let latestInput = poll?.input ?? outputControl.readInput()
    if latestInput != input { input = latestInput }
    let latestInputs = preservingEdit(poll?.inputDevices ?? outputControl.inputDevices(), input: true)
    if latestInputs != inputDevices { inputDevices = latestInputs }
    let resolved = resolvedOutput(poll?.output ?? outputControl.read())
    let deviceChanged = resolved.deviceUID != output.deviceUID
    if isEditingOutput {
      var edited = output
      edited.deviceName = resolved.deviceName
      edited.deviceUID = resolved.deviceUID
      edited.canChangeVolume = resolved.canChangeVolume
      if edited != output { output = edited }
    } else if output != resolved {
      output = resolved
    }
    if restartTaps && deviceChanged {
      reconcile()
    }
  }

  /// Core Audio can keep reporting the previous output for a moment after a Bluetooth switch.
  private func resolvedOutput(_ latest: SystemOutputState) -> SystemOutputState {
    var resolved = latest
    if let pending = pendingOutputUID {
      if latest.deviceUID == pending {
        pendingOutputUID = nil
        pendingOutputPreviousUID = nil
      } else if let previous = pendingOutputPreviousUID, let latestUID = latest.deviceUID, latestUID != previous {
        pendingOutputUID = nil
        pendingOutputPreviousUID = nil
      } else if let device = outputDevices.first(where: { $0.uid == pending }) {
        resolved.deviceUID = device.uid
        resolved.deviceName = device.name
        resolved.volume = device.volume
        resolved.isMuted = device.isMuted
        resolved.canChangeVolume = device.canChangeVolume
      } else {
        pendingOutputUID = nil
        pendingOutputPreviousUID = nil
      }
    }
    if let pin = outputPin {
      if pin.until > Date() {
        resolved.volume = pin.volume
      } else {
        outputPin = nil
      }
    }
    return resolved
  }

  private func preservingEdit(_ latest: [AudioOutputDevice], input: Bool) -> [AudioOutputDevice] {
    let now = Date()
    return latest.map { device in
      var copy = device
      if let editingDeviceUID, device.uid == editingDeviceUID,
        let current = (input ? inputDevices : outputDevices).first(where: { $0.uid == device.uid })
      {
        copy.volume = current.volume
        copy.isMuted = current.isMuted
      }
      let key = DeviceVolumeKey(uid: device.uid, input: input)
      if let pin = devicePins[key] {
        if pin.until > now {
          copy.volume = pin.volume
        } else {
          devicePins[key] = nil
        }
      }
      return copy
    }
  }

  private func store(_ level: AppAudioLevel, for key: String) {
    var level = level.clamped
    if let row = apps.first(where: { $0.key == key }) {
      if level.name.isEmpty { level.name = row.name }
      if level.bundlePath == nil { level.bundlePath = row.bundlePath }
    }
    if AppAudioRoute.needsTap(level) || level.routesToMultipleDevices {
      levels[key] = level
    } else {
      levels[key] = nil
    }
    if let index = apps.firstIndex(where: { $0.key == key }) {
      apps[index].level = level
      if !level.name.isEmpty { apps[index].name = level.name }
    }
    AppAudioLevelStore.save(levels, to: defaults)
  }

  private func syncTap(for _: String) {
    retryAfter.removeAll()
    reconcile()
  }

  /// Updates a running playback tap directly. Rebuilding the process list on every slider tick stalls the control.
  private func applyLevel(_ level: AppAudioLevel, for key: String) {
    let updated = level.clamped
    store(updated, for: key)
    if let tap = taps[key], tap.isRunning, !tap.rendersSilence,
      AppAudioRoute.needsTap(updated, systemDeviceUID: output.deviceUID)
    {
      tap.setGain(AppAudioRoute.gain(for: updated))
      tap.setEQ(updated.eqGains)
      syncAppGainRouter()
      return
    }
    reconcile()
  }

  private func syncAppGainRouter() {
    var playback: [String: any AppAudioTap] = [:]
    for (key, tap) in taps where tap.isRunning && !tap.rendersSilence {
      playback[key] = tap
    }
    appGains.replace(playback, levels: levels)
  }

  private func level(for key: String) -> AppAudioLevel {
    liveLevels[key] ?? levels[key] ?? apps.first { $0.key == key }?.level ?? .full
  }

  private struct DeviceVolumeKey: Hashable {
    var uid: String
    var input: Bool
  }

  private struct VolumePin {
    var volume: Double
    var until: Date
  }

  private func commitLiveDeviceVolumes() {
    let until = Date().addingTimeInterval(1.5)
    for (key, volume) in liveDeviceVolumes {
      updateDevice(key.uid, input: key.input) { device in
        device.volume = volume
      }
      devicePins[key] = VolumePin(volume: volume, until: until)
      if !key.input, output.deviceUID == key.uid {
        output.volume = volume
        outputPin = VolumePin(volume: volume, until: until)
      }
    }
    liveDeviceVolumes.removeAll()
  }

  private func writeDeviceVolume(_ volume: Double, uid: String, input: Bool) {
    if let deviceID = (input ? inputDevices : outputDevices).first(where: { $0.uid == uid })?.objectID,
      deviceID != kAudioObjectUnknown
    {
      let scope: AudioObjectPropertyScope =
        input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
      outputControl.setVolume(Float(volume), deviceID: deviceID, scope: scope)
    } else if input {
      outputControl.setInputVolume(Float(volume), deviceUID: uid)
    } else {
      outputControl.setVolume(Float(volume), deviceUID: uid)
    }
  }

  private func updateDevice(_ uid: String, input: Bool, change: (inout AudioOutputDevice) -> Void) {
    if input, let index = inputDevices.firstIndex(where: { $0.uid == uid }) {
      change(&inputDevices[index])
    } else if let index = outputDevices.firstIndex(where: { $0.uid == uid }) {
      change(&outputDevices[index])
    }
  }

  private func targetDeviceUIDs(for row: AppAudioRow) -> [String] {
    let selected = row.level.outputDeviceUIDs.filter { uid in
      outputDevices.contains { $0.uid == uid }
    }
    if !selected.isEmpty { return selected }
    guard let system = output.deviceUID, !system.isEmpty else { return [] }
    return [system]
  }

  private func normalizeDevicePins() {
    guard !outputDevices.isEmpty else { return }
    var changed = false
    for (key, level) in levels {
      let available = level.outputDeviceUIDs.filter { uid in outputDevices.contains { $0.uid == uid } }
      guard available != level.outputDeviceUIDs else { continue }
      var updated = level
      updated.outputDeviceUIDs = available
      levels[key] = (AppAudioRoute.needsTap(updated) || updated.routesToMultipleDevices) ? updated : nil
      changed = true
    }
    if changed {
      AppAudioLevelStore.save(levels, to: defaults)
    }
  }

  private enum TapSync {
    case running
    case waiting
    case failed(Int32)
  }

  private func ensureTap(
    for row: AppAudioRow,
    deviceUIDs: [String],
    rendersSilence: Bool,
    into storage: inout [String: any AppAudioTap]
  ) -> TapSync {
    let objectIDs = row.processes.map(\.objectID)
    let retryKey = rendersSilence ? "meter:\(row.key)" : row.key
    let tap = storage[row.key] ?? makeTap(row.key)
    storage[row.key] = tap
    let gain = AppAudioRoute.gain(for: row.level)
    let sameRoute = tap.outputDeviceUIDs == deviceUIDs && tap.rendersSilence == rendersSilence
      && tap.processObjectIDs == objectIDs
    if tap.isRunning && sameRoute {
      tap.setGain(gain)
      tap.setEQ(row.level.eqGains)
      return .running
    }
    // A failed start clears the tap route. Still honor the backoff, or a volume drag retries the tap on every tick.
    if let retry = retryAfter[retryKey], retry > Date() {
      return .waiting
    }
    tap.stop()
    do {
      try tap.start(processObjectIDs: objectIDs, outputDeviceUIDs: deviceUIDs, rendersSilence: rendersSilence)
      tap.setGain(gain)
      tap.setEQ(row.level.eqGains)
      retryAfter[retryKey] = nil
      return .running
    } catch let error as AppAudioTapError {
      retryAfter[retryKey] = Date().addingTimeInterval(5)
      if case .coreAudio(let status) = error {
        return .failed(status)
      }
      return .failed(0)
    } catch {
      retryAfter[retryKey] = Date().addingTimeInterval(5)
      return .failed(0)
    }
  }

  private func publishMeters() {
    var next: [String: AppAudioMeter] = [:]
    let active = taps.merging(meterTaps) { playback, _ in playback }
    for (key, tap) in active {
      let peak = tap.consumePeaks()
      let previous = displayedMeters[key] ?? .silent
      next[key] = AppAudioMeter(
        left: min(1, max(Double(peak.left), previous.left * 0.84)),
        right: min(1, max(Double(peak.right), previous.right * 0.84))
      )
    }
    displayedMeters = next
    levelMeters.update(next)
  }

  private func stopPlayback(for key: String) {
    taps[key]?.stop()
    taps[key] = nil
    retryAfter[key] = nil
  }

  private func stopMeter(for key: String) {
    meterTaps[key]?.stop()
    meterTaps[key] = nil
    retryAfter["meter:\(key)"] = nil
  }

  private func row(for group: AppAudioGroup) -> AppAudioRow {
    let resolved = group.processes.first.map(AppAudioProcessName.resolve)
    let saved = levels[group.key]
    let name = AppAudioProcessName.displayName(resolved?.name ?? saved?.name ?? group.key)
    let bundlePath = resolved?.bundlePath ?? saved?.bundlePath
    var level = group.level
    if level.name.isEmpty { level.name = name }
    if level.bundlePath == nil { level.bundlePath = bundlePath }
    return AppAudioRow(
      key: group.key,
      name: name,
      bundlePath: bundlePath,
      level: level,
      isPlaying: group.isPlaying,
      processes: group.processes
    )
  }

  private func sortRows(_ lhs: AppAudioRow, _ rhs: AppAudioRow) -> Bool {
    if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying && !rhs.isPlaying }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  private func stopAllTaps() {
    for tap in taps.values { tap.stop() }
    for tap in meterTaps.values { tap.stop() }
    taps.removeAll()
    meterTaps.removeAll()
    displayedMeters = [:]
    levelMeters.update([:])
    appGains.replace([:], levels: levels)
  }
}
