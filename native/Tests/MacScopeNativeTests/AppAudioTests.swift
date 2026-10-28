import CoreAudio
import Foundation
import Testing

@testable import MacScopeNative

@Suite("Application audio")
struct AppAudioTests {
  @Test("Unity gain stays on the system path, and mute or a lower level needs a tap")
  func tapPolicy() throws {
    #expect(!AppAudioRoute.needsTap(.full))
    #expect(AppAudioRoute.gain(for: .full) == 1)

    var quieter = AppAudioLevel.full
    quieter.volume = 0.4
    #expect(AppAudioRoute.needsTap(quieter))
    #expect(AppAudioRoute.gain(for: quieter) == 0.4)

    var muted = AppAudioLevel.full
    muted.isMuted = true
    #expect(AppAudioRoute.needsTap(muted))
    #expect(AppAudioRoute.gain(for: muted) == 0)

    var routed = AppAudioLevel.full
    routed.outputDeviceUIDs = ["headphones"]
    #expect(AppAudioRoute.needsTap(routed))
    #expect(AppAudioRoute.needsTap(routed, systemDeviceUID: "speakers"))
    #expect(!AppAudioRoute.needsTap(routed, systemDeviceUID: "headphones"))

    var boosted = AppAudioLevel.full
    boosted.boost = 2
    #expect(AppAudioRoute.needsTap(boosted, systemDeviceUID: "speakers"))
    #expect(AppAudioRoute.gain(for: boosted) == 2)

    var split = AppAudioLevel.full
    split.outputDeviceUIDs = ["speakers", "headphones"]
    #expect(AppAudioRoute.needsTap(split, systemDeviceUID: "speakers"))

    let legacy = #"{"volume":0.5,"isMuted":false,"name":"Saved","outputDeviceUID":"headphones"}"#
    let decoded = try JSONDecoder().decode(AppAudioLevel.self, from: Data(legacy.utf8))
    #expect(decoded.outputDeviceUIDs == ["headphones"])
    #expect(decoded.boost == 1)
  }

  @Test("Audio helpers inside an app bundle belong to that app")
  func groupsOwningApplication() {
    let renderer =
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    let helper =
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(AppAudioOwningApp.applicationPath(executablePath: renderer) == "/Applications/Google Chrome.app")
    let first = AudioProcessSnapshot(objectID: 1, pid: 1, bundleID: "helper.renderer", executablePath: renderer)
    let second = AudioProcessSnapshot(objectID: 2, pid: 2, bundleID: "helper.gpu", executablePath: helper)
    #expect(AppAudioOwningApp.groupKey(for: first) == AppAudioOwningApp.groupKey(for: second))
    let groups = AppAudioCatalog.groups(
      processes: [first, second],
      levels: [:],
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    #expect(groups.count == 1)
    #expect(groups.first?.processes.map(\.pid) == [1, 2])

    let faceTime = AudioProcessSnapshot(
      objectID: 3,
      pid: 3,
      bundleID: "com.apple.avconferenced",
      executablePath: "/usr/libexec/avconferenced"
    )
    let faceTimeApp = "/System/Applications/FaceTime.app"
    if FileManager.default.fileExists(atPath: faceTimeApp) {
      #expect(AppAudioOwningApp.groupKey(for: faceTime) == "com.apple.FaceTime")
      #expect(AppAudioProcessName.resolve(faceTime).bundlePath == faceTimeApp)
      #expect(AppAudioProcessName.resolve(faceTime).name != "avconferenced")
    }
    #expect(AppAudioMeter.visual(0) == 0)
    #expect(AppAudioMeter.visual(1) == 1)
    #expect(AppAudioMeter.visual(0.1) > 0.45)
    #expect(AppAudioMeter.visual(0.1) < 0.6)
  }

  @Test("Processes with one bundle share a level, and this app is excluded")
  func groupsProcesses() {
    let processes = [
      AudioProcessSnapshot(objectID: 10, pid: 10, bundleID: "com.example.player"),
      AudioProcessSnapshot(objectID: 11, pid: 11, bundleID: "com.example.player"),
      AudioProcessSnapshot(objectID: 12, pid: 12, bundleID: "com.shenmuoso.macscope"),
      AudioProcessSnapshot(objectID: 13, pid: 13, bundleID: nil),
    ]
    let groups = AppAudioCatalog.groups(
      processes: processes,
      levels: ["com.example.saved": AppAudioLevel(volume: 0.2, isMuted: false, name: "Saved", bundlePath: nil)],
      excludedPIDs: [],
      excludedBundleIDs: ["com.shenmuoso.macscope"]
    )

    let player = groups.first { $0.key == "com.example.player" }
    #expect(player?.processes.map(\.pid) == [10, 11])
    #expect(groups.contains { $0.key == "com.shenmuoso.macscope" } == false)
    #expect(groups.contains { $0.key == "pid:13" })
    #expect(groups.first { $0.key == "com.example.saved" }?.level.volume == 0.2)
    #expect(groups.first { $0.key == "com.example.saved" }?.isPlaying == false)
  }

  @Test("Float audio is scaled into the output buffers")
  func scalesSamples() {
    let stereo = AppAudioGain.renderSamples(
      input: [[1, -1], [0.5, 0.25]],
      inputInterleaved: true,
      outputChannelCount: 2,
      outputInterleaved: true,
      gain: 0.5
    )
    #expect(stereo[0] == [0.5, -0.5])
    #expect(stereo[1] == [0.25, 0.125])

    let silenced = AppAudioGain.renderSamples(
      input: [[1, 1]],
      inputInterleaved: false,
      outputChannelCount: 2,
      outputInterleaved: false,
      gain: 0
    )
    #expect(silenced == [[0, 0], [0, 0]])

    let monoToStereo = AppAudioGain.renderSamples(
      input: [[0.5, 1]],
      inputInterleaved: false,
      outputChannelCount: 2,
      outputInterleaved: false,
      gain: 1
    )
    #expect(monoToStereo == [[0.5, 1], [0.5, 1]])

    let fanOut = AppAudioGain.renderSamples(
      input: [[1, 0.5], [-1, 0.25]],
      inputInterleaved: false,
      outputChannelCount: 4,
      outputInterleaved: false,
      gain: 1
    )
    #expect(fanOut == [[1, 0.5], [-1, 0.25], [1, 0.5], [-1, 0.25]])
    #expect(AppAudioGain.peakSamples([[0.2, -0.8], [0.4, 0.1]], interleaved: false).left == 0.8)
    #expect(AppAudioGain.peakSamples([[0.2, -0.8], [0.4, 0.1]], interleaved: false).right == 0.4)
  }

  @Test("A flat equalizer leaves the signal unchanged, and a boosted band raises it")
  func shapesEqualizer() {
    let tone = (0..<256).map { index in
      sin(2 * Float.pi * 1_000 * Float(index) / 48_000)
    }
    let flat = AppAudioEQ.render(samples: tone, gains: AppAudioEQ.flat, sampleRate: 48_000)
    #expect(zip(tone, flat).allSatisfy { abs($0 - $1) < 0.0001 })

    var gains = AppAudioEQ.flat
    gains[5] = 12
    let boosted = AppAudioEQ.render(samples: tone, gains: gains, sampleRate: 48_000)
    let boostedPeak = boosted.suffix(64).map(abs).max() ?? 0
    #expect(boostedPeak > 2)
  }

  @Test("Only a changed application starts a tap, and full volume removes it")
  @MainActor
  func controllerStartsAndStopsTaps() async throws {
    let suiteName = "AppAudioTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let processes = FakeAudioProcesses()
    processes.snapshots = [
      AudioProcessSnapshot(objectID: 7, pid: 70, bundleID: "com.example.player")
    ]
    let output = FakeSystemOutput()
    let tap = FakeAppAudioTap()
    let controller = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in tap },
      excludedPIDs: [],
      excludedBundleIDs: []
    )

    await controller.reconcile()
    #expect(tap.isRunning)
    #expect(tap.rendersSilence)
    #expect(tap.outputDeviceUIDs == ["speakers"])

    await controller.setVolume(0.25, for: "com.example.player")
    #expect(tap.isRunning)
    #expect(tap.rendersSilence == false)
    #expect(tap.gain == 0.25)
    let startsWhileDragging = tap.startCount
    await controller.setVolume(0.4, for: "com.example.player")
    #expect(tap.startCount == startsWhileDragging)
    #expect(tap.gain == 0.4)
    #expect(tap.processObjectIDs == [7])
    #expect(tap.outputDeviceUIDs == ["speakers"])

    await controller.setMuted(true, for: "com.example.player")
    #expect(tap.gain == 0)
    #expect(tap.isRunning)

    output.state.deviceUID = "headphones"
    await controller.reconcile()
    #expect(tap.startCount == 3)
    #expect(tap.outputDeviceUIDs == ["headphones"])

    await controller.setMuted(false, for: "com.example.player")
    await controller.setVolume(1, for: "com.example.player")
    #expect(tap.isRunning)
    #expect(tap.rendersSilence)

    let restored = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in FakeAppAudioTap() },
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    await restored.reconcile()
    #expect(restored.apps.first { $0.key == "com.example.player" }?.level.volume == 1)
  }

  @Test("A chosen output device stays when the system default changes")
  @MainActor
  func routesAnAppToItsOwnDevice() async throws {
    let suiteName = "AppAudioTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let processes = FakeAudioProcesses()
    processes.snapshots = [
      AudioProcessSnapshot(objectID: 7, pid: 70, bundleID: "com.example.player")
    ]
    let output = FakeSystemOutput()
    let tap = FakeAppAudioTap()
    let controller = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in tap },
      excludedPIDs: [],
      excludedBundleIDs: []
    )

    await controller.reconcile()
    await controller.setAppOutputDevices(["headphones"], for: "com.example.player")
    #expect(tap.isRunning)
    #expect(tap.rendersSilence == false)
    #expect(tap.outputDeviceUIDs == ["headphones"])
    #expect(tap.gain == 1)

    output.state.deviceUID = "other"
    await controller.reconcile()
    #expect(tap.outputDeviceUIDs == ["headphones"])
    #expect(tap.startCount == 2)

    await controller.setMultipleRoutes(true, for: "com.example.player")
    await controller.toggleAppOutputDevice("speakers", for: "com.example.player")
    #expect(tap.outputDeviceUIDs == ["headphones", "speakers"])

    await controller.setAppOutputDevices([], for: "com.example.player")
    #expect(tap.isRunning)
    #expect(tap.rendersSilence)
  }

  @Test("Dragging application volume does not rebuild the tap or publish every tick")
  @MainActor
  func draggingVolumeSkipsPublish() async throws {
    let suiteName = "AppAudioTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let processes = FakeAudioProcesses()
    processes.snapshots = [
      AudioProcessSnapshot(objectID: 7, pid: 70, bundleID: "com.example.player")
    ]
    let output = FakeSystemOutput()
    let tap = FakeAppAudioTap()
    let controller = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in tap },
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    await controller.reconcile()
    await controller.setVolume(0.25, for: "com.example.player")
    let starts = tap.startCount

    controller.beginAppVolumeEdit()
    await controller.setInteractiveVolume(0.4, for: "com.example.player")
    await controller.setInteractiveVolume(0.55, for: "com.example.player")
    #expect(tap.startCount == starts)
    #expect(tap.gain == 0.55)
    #expect(controller.apps.first?.level.volume == 0.25)

    controller.endAppVolumeEdit()
    #expect(controller.apps.first?.level.volume == 0.55)
    let restored = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in FakeAppAudioTap() },
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    await restored.reconcile()
    #expect(restored.apps.first?.level.volume == 0.55)
  }

  @Test("A failed tap is not started again on every volume change")
  @MainActor
  func failedTapWaitsBeforeRetrying() async throws {
    let suiteName = "AppAudioTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let processes = FakeAudioProcesses()
    processes.snapshots = [
      AudioProcessSnapshot(objectID: 7, pid: 70, bundleID: "com.example.player")
    ]
    let tap = FakeAppAudioTap()
    let controller = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: FakeSystemOutput(),
      makeTap: { _ in tap },
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    await controller.reconcile()
    tap.startError = AppAudioTapError.unsupported
    await controller.setVolume(0.25, for: "com.example.player")
    let attempts = tap.startCount
    await controller.setInteractiveVolume(0.4, for: "com.example.player")
    await controller.reconcile()
    #expect(tap.startCount == attempts)
  }

  @Test("Choosing Bluetooth keeps the route when the default device has not switched yet")
  @MainActor
  func pendingOutputFollowsTheChosenDevice() async throws {
    let suiteName = "AppAudioTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let processes = FakeAudioProcesses()
    processes.snapshots = [
      AudioProcessSnapshot(objectID: 7, pid: 70, bundleID: "com.example.player")
    ]
    let output = FakeSystemOutput()
    output.devices.append(
      AudioOutputDevice(objectID: 3, uid: "display", name: "Display", transport: kAudioDeviceTransportTypeHDMI)
    )
    let tap = FakeAppAudioTap()
    let controller = AppAudioController(
      defaults: defaults,
      processes: processes,
      outputControl: output,
      makeTap: { _ in tap },
      excludedPIDs: [],
      excludedBundleIDs: []
    )
    await controller.reconcile()
    await controller.setVolume(0.5, for: "com.example.player")
    #expect(tap.outputDeviceUIDs == ["speakers"])

    output.appliesDefaultChange = false
    await controller.setDefaultOutputDevice("headphones")
    #expect(controller.output.deviceUID == "headphones")
    #expect(tap.outputDeviceUIDs == ["headphones"])
    #expect(tap.rendersSilence == false)

    await controller.reconcile()
    #expect(tap.outputDeviceUIDs == ["headphones"])

    output.state.deviceUID = "display"
    output.state.deviceName = "Display"
    await controller.reconcile()
    #expect(controller.output.deviceUID == "display")
    #expect(tap.outputDeviceUIDs == ["display"])
  }

  @Test("The current output device and playing processes can be read")
  func readsLiveOutput() {
    let state = SystemOutputControl().read()
    #expect(state.volume >= 0 && state.volume <= 1)
    let processes = CoreAudioAppProcessList().outputProcesses()
    #expect(processes.allSatisfy { $0.pid > 0 })
  }
}

private final class FakeAudioProcesses: AppAudioProcessListing, @unchecked Sendable {
  var snapshots: [AudioProcessSnapshot] = []

  func outputProcesses() -> [AudioProcessSnapshot] { snapshots }
}

private final class FakeSystemOutput: SystemOutputControlling, @unchecked Sendable {
  var state = SystemOutputState(
    deviceName: "Speakers",
    deviceUID: "speakers",
    volume: 0.8,
    isMuted: false,
    canChangeVolume: true
  )

  var devices = [
    AudioOutputDevice(objectID: 1, uid: "speakers", name: "Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
    AudioOutputDevice(
      objectID: 2,
      uid: "headphones",
      name: "Headphones",
      transport: kAudioDeviceTransportTypeBluetooth
    ),
  ]

  var appliesDefaultChange = true

  func read() -> SystemOutputState { state }
  func outputDevices() -> [AudioOutputDevice] { devices }
  func setDefaultDevice(uid: String) {
    guard appliesDefaultChange, let device = devices.first(where: { $0.uid == uid }) else { return }
    state.deviceUID = device.uid
    state.deviceName = device.name
  }
  func setVolume(_ volume: Float) { state.volume = Double(volume) }
  func setMuted(_ muted: Bool) { state.isMuted = muted }
  func observe(_ handler: @escaping @Sendable () -> Void) {}
}

private final class FakeAppAudioTap: AppAudioTap, @unchecked Sendable {
  private(set) var processObjectIDs: [AudioObjectID] = []
  private(set) var outputDeviceUIDs: [String] = []
  private(set) var rendersSilence = false
  private(set) var isRunning = false
  private(set) var gain: Float = 1
  private(set) var startCount = 0
  var startError: Error?

  func start(processObjectIDs: [AudioObjectID], outputDeviceUIDs: [String], rendersSilence: Bool) throws {
    startCount += 1
    if let startError { throw startError }
    self.processObjectIDs = processObjectIDs
    self.outputDeviceUIDs = outputDeviceUIDs
    self.rendersSilence = rendersSilence
    isRunning = true
  }

  func setGain(_ gain: Float) {
    self.gain = gain
  }

  func setEQ(_ gains: [Double]) {}

  func consumePeaks() -> (left: Float, right: Float) { (0, 0) }

  func stop() {
    isRunning = false
    rendersSilence = false
    outputDeviceUIDs = []
    processObjectIDs = []
  }
}
