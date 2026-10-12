import Foundation
import Testing

@testable import MacScopeNative

@Suite("Display adjustment synchronization", .timeLimit(.minutes(1)))
@MainActor
struct DisplayAdjustmentTests {
  @Test("Dragging updates immediately, coalesces writes, and preserves the requested percentage")
  func immediateFeedback() async {
    let hardware = ControlledDisplayHardware()
    let display = display()
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)

    store.setBrightness(45, feature: nil, display: display)
    store.setBrightness(60, feature: nil, display: display)
    let task = store.setBrightness(75, feature: nil, display: display)
    #expect(store.percent(for: nil, display: display) == 75)
    #expect(store.busyDisplays.isEmpty)
    await hardware.waitForWrites(1)
    #expect(await hardware.writes.map(\.percent) == [75])
    await hardware.finishWrite(actual: 74.7)
    await task?.value

    #expect(store.percent(for: nil, display: display) == 75)
    #expect(store.hardware[display.id]?.brightness == 74.7)
    #expect(store.adjustingControls.isEmpty)
    #expect(store.operationError == nil)
    #expect(await hardware.readCount == 1)
  }

  @Test("An in-flight response cannot overwrite a newer drag, and only the last queued value is written")
  func latestRequestWins() async {
    let hardware = ControlledDisplayHardware()
    let display = display()
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)
    store.setBrightness(50, feature: nil, display: display)
    await hardware.waitForWrites(1)
    store.setBrightness(60, feature: nil, display: display)
    let task = store.setBrightness(80, feature: nil, display: display)
    await hardware.finishWrite(actual: 49.8)
    await hardware.waitForWrites(2)

    #expect(store.percent(for: nil, display: display) == 80)
    #expect(store.hardware[display.id]?.brightness == 49.8)
    #expect(await hardware.writes.map(\.percent) == [50, 80])
    await hardware.finishWrite(actual: 80)
    await task?.value
    #expect(store.percent(for: nil, display: display) == 80)
    #expect(await hardware.readCount == 1)
  }

  @Test("A superseded failure is silent; failure of the latest request restores the confirmed value")
  func failuresRespectNewerInput() async {
    let hardware = ControlledDisplayHardware()
    let display = display()
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)
    store.setBrightness(50, feature: nil, display: display)
    await hardware.waitForWrites(1)
    let task = store.setBrightness(80, feature: nil, display: display)
    await hardware.failWrite()
    await hardware.waitForWrites(2)

    #expect(store.percent(for: nil, display: display) == 80)
    #expect(store.operationError == nil)
    await hardware.failWrite()
    await task?.value
    #expect(store.percent(for: nil, display: display) == 40)
    #expect(store.operationError == DisplayControlError.brightnessFailed.rawValue)
    #expect(store.adjustingControls.isEmpty)
  }

  @Test("DDC controls update independently without probing unrelated features or disabling the display")
  func independentDDCControls() async {
    let hardware = ControlledDisplayHardware()
    let display = display(builtIn: false)
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)
    let brightnessTask = store.setBrightness(70, feature: .brightness, display: display)
    let contrastTask = store.setBrightness(65, feature: .contrast, display: display)
    await hardware.waitForWrites(2)
    #expect(store.percent(for: .brightness, display: display) == 70)
    #expect(store.percent(for: .contrast, display: display) == 65)
    #expect(store.busyDisplays.isEmpty)
    await hardware.finishWrite(feature: .brightness, actual: 69.5)
    await hardware.finishWrite(feature: .contrast, actual: 65)
    await brightnessTask?.value
    await contrastTask?.value

    #expect(store.percent(for: .brightness, display: display) == 70)
    #expect(store.hardware[display.id]?.ddc[.brightness]?.percent == 69.5)
    #expect(store.hardware[display.id]?.ddc[.contrast]?.percent == 65)
    #expect(store.hardware[display.id]?.ddc[.volume] == nil)
    #expect(await hardware.readCount == 1)
  }

  @Test("A refresh begun before a drag cannot publish its stale hardware snapshot")
  func staleRefresh() async {
    let hardware = ControlledDisplayHardware()
    let display = display()
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)
    await hardware.holdNextRead()
    let refresh = Task { await store.loadControls(display) }
    await hardware.waitForReads(2)
    let write = store.setBrightness(80, feature: nil, display: display)
    await hardware.waitForWrites(1)
    await hardware.finishWrite(actual: 80)
    await write?.value
    await hardware.finishRead(brightness: 40)
    await refresh.value

    #expect(store.hardware[display.id]?.brightness == 80)
    #expect(store.percent(for: nil, display: display) == 80)
  }

  @Test("Refresh preserves rounding after success but reflects a subsequent external brightness change")
  func refreshAfterConfirmation() async {
    let hardware = ControlledDisplayHardware()
    let display = display()
    let store = DisplayControlStore(displays: [display], hardwareControl: hardware)
    await store.loadControls(display)
    let task = store.setBrightness(75, feature: nil, display: display)
    await hardware.waitForWrites(1)
    await hardware.finishWrite(actual: 74.7)
    await task?.value
    await hardware.setBrightnessSnapshot(74.7)
    await store.loadControls(display)
    #expect(store.percent(for: nil, display: display) == 75)
    await hardware.setBrightnessSnapshot(30)
    await store.loadControls(display)
    #expect(store.percent(for: nil, display: display) == 30)
  }

  private func display(builtIn: Bool = true) -> DisplaySummary {
    .init(
      id: "test-display", displayID: 42, identity: "test-identity", name: "Test Display",
      isBuiltIn: builtIn, isMain: true, boundsWidth: 1920, boundsHeight: 1080,
      currentMode: nil, modes: [], colorProfile: "", colorSpace: ""
    )
  }
}

private actor ControlledDisplayHardware: DisplayHardwareControlling {
  struct Write: Sendable {
    let feature: DDCFeature?
    let percent: Double
  }

  private(set) var writes: [Write] = []
  private(set) var readCount = 0
  private var brightness = 40.0
  private var pendingWrites: [DDCFeature?: CheckedContinuation<Double, any Error>] = [:]
  private var writeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var holdingRead = false
  private var pendingRead: CheckedContinuation<DisplayHardwareSnapshot, Never>?

  func read(displayID: UInt32, identity: String, builtIn: Bool) async -> DisplayHardwareSnapshot {
    readCount += 1
    let ready = readWaiters.filter { $0.0 <= readCount }
    readWaiters.removeAll { $0.0 <= readCount }
    for (_, waiter) in ready { waiter.resume() }
    if holdingRead {
      holdingRead = false
      return await withCheckedContinuation { pendingRead = $0 }
    }
    return snapshot(brightness)
  }

  func setNativeBrightness(_ percent: Double, displayID: UInt32, identity: String) async throws -> Double {
    try await write(percent, feature: nil)
  }

  func setDDC(_ feature: DDCFeature, percent: Double, displayID: UInt32, identity: String) async throws -> DDCValue {
    let actual = try await write(percent, feature: feature)
    return .init(current: UInt16((actual * 2).rounded()), maximum: 200)
  }

  private func write(_ percent: Double, feature: DDCFeature?) async throws -> Double {
    writes.append(.init(feature: feature, percent: percent))
    let ready = writeWaiters.filter { $0.0 <= writes.count }
    writeWaiters.removeAll { $0.0 <= writes.count }
    for (_, waiter) in ready { waiter.resume() }
    return try await withCheckedThrowingContinuation { pendingWrites[feature] = $0 }
  }

  func waitForWrites(_ count: Int) async {
    if writes.count >= count { return }
    await withCheckedContinuation { writeWaiters.append((count, $0)) }
  }

  func finishWrite(feature: DDCFeature? = nil, actual: Double) {
    pendingWrites.removeValue(forKey: feature)?.resume(returning: actual)
  }

  func failWrite() {
    pendingWrites.removeValue(forKey: nil)?.resume(throwing: DisplayControlError.brightnessFailed)
  }

  func holdNextRead() { holdingRead = true }

  func waitForReads(_ count: Int) async {
    if readCount >= count { return }
    await withCheckedContinuation { readWaiters.append((count, $0)) }
  }

  func finishRead(brightness: Double) {
    pendingRead?.resume(returning: snapshot(brightness))
    pendingRead = nil
  }

  func setBrightnessSnapshot(_ value: Double) { brightness = value }

  private func snapshot(_ brightness: Double) -> DisplayHardwareSnapshot {
    .init(brightness: brightness, ddc: [.brightness: .init(current: 40, maximum: 100), .contrast: .init(current: 50, maximum: 100)], error: nil)
  }

  func colorConfiguration(_ displayID: UInt32) -> DisplayColorConfiguration {
    .init(profiles: [], selectedID: "factory", factoryName: "Default", factoryURL: nil, isAvailable: false)
  }

  func setProfile(_ id: String, displayID: UInt32, identity: String) -> DisplayColorConfiguration {
    colorConfiguration(displayID)
  }
}
