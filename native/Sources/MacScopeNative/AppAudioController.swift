import Foundation

struct AppAudioMeter: Equatable {
  var left: Double
  var right: Double

  static let silent = AppAudioMeter(left: 0, right: 0)
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
  @Published private(set) var meters: [String: AppAudioMeter] = [:]
  @Published private(set) var perAppErrorKey: String?
  @Published private(set) var lastTapStatus: Int32?

  private var levels: [String: AppAudioLevel]
  private var taps: [String: any AppAudioTap] = [:]
  private var meterTaps: [String: any AppAudioTap] = [:]
  private var displayedMeters: [String: AppAudioMeter] = [:]
  private var retryAfter: [String: Date] = [:]
  private var monitor: Task<Void, Never>?
  private var meterMonitor: Task<Void, Never>?
  private var isEditingOutput = false
  private var editingDeviceUID: String?
  private let defaults: UserDefaults
  private let processes: any AppAudioProcessListing
  private let outputControl: any SystemOutputControlling
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
        self?.refreshOutput(restartTaps: true)
      }
    }
    reconcile()
    monitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        self?.refreshOutput(restartTaps: false)
        self?.reconcile()
      }
    }
    meterMonitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 33_000_000)
        guard !Task.isCancelled else { return }
        self?.publishMeters()
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
    monitor?.cancel()
    monitor = nil
    meterMonitor?.cancel()
    meterMonitor = nil
    stopAllTaps()
  }

  func setOutputEditing(_ isEditing: Bool) {
    isEditingOutput = isEditing
    if !isEditing {
      refreshOutput(restartTaps: false)
    }
  }

  func setOutputVolume(_ volume: Double) {
    let clamped = min(1, max(0, volume))
    output.volume = clamped
    outputControl.setVolume(Float(clamped))
  }

  func setOutputMuted(_ isMuted: Bool) {
    output.isMuted = isMuted
    outputControl.setMuted(isMuted)
  }

  func setDefaultOutputDevice(_ uid: String) {
    guard !uid.isEmpty else { return }
    outputControl.setDefaultDevice(uid: uid)
    refreshOutput(restartTaps: true)
  }

  func setDefaultInputDevice(_ uid: String) {
    guard !uid.isEmpty else { return }
    outputControl.setDefaultInputDevice(uid: uid)
    refreshOutput(restartTaps: false)
  }

  func setDeviceEditing(_ uid: String?) {
    editingDeviceUID = uid
    if uid == nil {
      refreshOutput(restartTaps: false)
    }
  }

  func setDeviceVolume(_ volume: Double, uid: String, input: Bool) {
    let clamped = min(1, max(0, volume))
    updateDevice(uid, input: input) { device in
      device.volume = clamped
    }
    if input {
      outputControl.setInputVolume(Float(clamped), deviceUID: uid)
    } else {
      outputControl.setVolume(Float(clamped), deviceUID: uid)
      if output.deviceUID == uid {
        output.volume = clamped
      }
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
    store(level, for: key)
    syncTap(for: key)
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
    store(level, for: key)
    syncTap(for: key)
  }

  func setMuted(_ isMuted: Bool, for key: String) {
    var level = level(for: key)
    level.isMuted = isMuted
    store(level, for: key)
    syncTap(for: key)
  }

  func reconcile() {
    refreshOutput(restartTaps: false)
    normalizeDevicePins()
    let groups = AppAudioCatalog.groups(
      processes: processes.outputProcesses(),
      levels: levels,
      excludedPIDs: excludedPIDs,
      excludedBundleIDs: excludedBundleIDs
    )
    apps = groups.map(row(for:)).sorted(by: sortRows)
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
    perAppErrorKey = failed ? "MacScope could not adjust one or more application volumes." : nil
    if let status {
      lastTapStatus = status
    } else if !failed {
      lastTapStatus = nil
    }
  }

  private func refreshOutput(restartTaps: Bool) {
    let latest = outputControl.read()
    outputDevices = preservingEdit(outputControl.outputDevices())
    input = outputControl.readInput()
    inputDevices = preservingEdit(outputControl.inputDevices())
    let deviceChanged = latest.deviceUID != output.deviceUID
    if isEditingOutput {
      output.deviceName = latest.deviceName
      output.deviceUID = latest.deviceUID
      output.canChangeVolume = latest.canChangeVolume
    } else {
      output = latest
    }
    if restartTaps && deviceChanged {
      reconcile()
    }
  }

  private func preservingEdit(_ latest: [AudioOutputDevice]) -> [AudioOutputDevice] {
    guard let editingDeviceUID,
      let current = (outputDevices + inputDevices).first(where: { $0.uid == editingDeviceUID })
    else { return latest }
    return latest.map { device in
      guard device.uid == editingDeviceUID else { return device }
      var copy = device
      copy.volume = current.volume
      copy.isMuted = current.isMuted
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
    reconcile()
  }

  private func level(for key: String) -> AppAudioLevel {
    levels[key] ?? apps.first { $0.key == key }?.level ?? .full
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
    if tap.isRunning && tap.outputDeviceUIDs == deviceUIDs && tap.rendersSilence == rendersSilence
      && tap.processObjectIDs == objectIDs
    {
      tap.setGain(gain)
      tap.setEQ(row.level.eqGains)
      return .running
    }
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
    if next != meters {
      meters = next
    }
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
    meters = [:]
  }
}
