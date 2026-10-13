import CoreGraphics
import Foundation
import Testing

@testable import MacScopeNative

@Suite("Native display mode enumeration and switching", .timeLimit(.minutes(1)))
@MainActor
struct DisplayModeControlTests {
  @Test("A cold catalog at 1024x576 includes hidden 1920x1080 HiDPI at 120 Hz")
  func coldCatalog() throws {
    let choices = try catalog()
    let target = try #require(choices.first { $0.nativeIndex == 113 })
    #expect(choices.count == 4)
    #expect(target.summary.resolutionLabel == "1920 × 1080")
    #expect(target.summary.pixelResolutionLabel == "3840 × 2160")
    #expect(target.summary.isHiDPI)
    #expect(target.summary.refreshRate == 120)
    #expect(target.systemMode == nil)
    #expect(choices.filter { $0.summary.isCurrent }.count == 1)
  }

  @Test("Public I/O IDs map explicitly to native indices and refine fractional refresh rates")
  func distinctNamespaces() throws {
    let native = try #require(DisplayNativeMode(index: 113, data: descriptor(width: 1920, height: 1080, hz: 59)))
    let precise = summary(id: "io-501", width: 1920, height: 1080, hz: 59.939987, current: true)
    let choices = DisplayModeCatalog.merge(
      publicModes: [.init(summary: precise, nativeIndex: nil)], nativeModes: [native],
      publicIndices: [precise.id: 113], currentIndex: 113, kind: { _ in .fixed }
    )
    #expect(choices.count == 1)
    #expect(choices.first?.nativeIndex == 113)
    #expect(choices.first?.summary.refreshRate == 59.939987)
    #expect(choices.first?.summary.isRefreshRateTruncated == false)
    #expect(choices.first?.summary.isCurrent == true)
    #expect(choices.first?.summary.matches(precise) == true)
  }

  @Test("Current hidden modes merge through the native current-index query, without a legacy mapping")
  func currentHiddenMode() throws {
    let choices = try catalog(startHiDPI: true)
    #expect(choices.count == 4)
    #expect(choices.filter { $0.summary.isCurrent }.map(\.nativeIndex) == [113])
    #expect(choices.first?.summary.pixelWidth == 3840)
  }

  @Test("Unavailable optional native APIs leave public modes usable")
  func publicOnly() {
    let current = summary(id: "public", current: true)
    let choices = DisplayModeCatalog.merge(
      publicModes: [.init(summary: current, nativeIndex: nil)], nativeModes: [],
      publicIndices: [:], currentIndex: nil, kind: { _ in .unknown }
    )
    #expect(choices.map(\.summary) == [current])
  }

  @Test("Descriptor decoding rejects unusable, truncated, corrupt and inconsistent records")
  func invalidDescriptors() {
    #expect(DisplayNativeMode(index: 113, data: Data(repeating: 0, count: 211)) == nil)
    #expect(DisplayNativeMode(index: 113, data: descriptor(flags: 0x4000_0000)) == nil)
    #expect(DisplayNativeMode(index: 113, data: descriptor(width: 0)) == nil)
    #expect(DisplayNativeMode(index: -1, data: descriptor()) == nil)
    #expect(DisplayNativeMode(index: 113, data: descriptor(density: .nan)) == nil)
    #expect(DisplayNativeMode(index: 113, data: descriptor(density: 1)) == nil)
  }

  @Test("Starting at 1024x576 can select hidden HiDPI directly, without saved history")
  func coldSwitchAndRestore() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let store = makeStore(access)
    let display = display(access)
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    await store.apply(modeID: target.summary.id, to: display)?.value
    #expect(access.writes.map(\.nativeIndex) == [113])
    #expect(access.actual?.pixelWidth == 3840)
    #expect(access.actual?.refreshRate == 120)
    #expect(store.pendingChange != nil)
    #expect(!store.isChangingMode)
    await store.restorePendingChange()?.value
    #expect(access.writes.map(\.nativeIndex) == [113, 23])
    #expect(access.actual?.width == 1024)
    #expect(store.pendingChange == nil)
  }

  @Test("HiDPI remains selectable and restores when absent from the public table after switching")
  func hiddenRestore() async throws {
    let access = try ControlledModeAccess(choices: catalog(startHiDPI: true))
    let store = makeStore(access)
    let low = try #require(access.choices.first { $0.nativeIndex == 23 })
    await store.apply(modeID: low.summary.id, to: display(access))?.value
    access.choices = try catalog()
    await store.restorePendingChange()?.value
    #expect(access.writes.map(\.nativeIndex) == [23, 113])
    #expect(access.actual?.width == 1920)
    #expect(access.actual?.pixelWidth == 3840)
    #expect(store.pendingChange == nil)
    #expect(store.operationError == nil)
  }

  @Test("Restore reacquires a renumbered mode by geometry, density and refresh type")
  func renumberedRestore() async throws {
    let access = try ControlledModeAccess(choices: catalog(startHiDPI: true))
    let store = makeStore(access)
    let low = try #require(access.choices.first { $0.nativeIndex == 23 })
    await store.apply(modeID: low.summary.id, to: display(access))?.value
    let replacement = summary(id: "renumbered", width: 1920, height: 1080)
    access.choices = [low, .init(summary: replacement, nativeIndex: 213)]
    await store.restorePendingChange()?.value
    #expect(access.writes.map(\.nativeIndex) == [23, 213])
    #expect(store.pendingChange == nil)
  }

  @Test("Missing HiDPI is never replaced by standard 1080p, a different Hz or adaptive refresh")
  func noDensityOrRefreshDowngrade() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let target = summary(id: "missing", width: 1920, height: 1080)
    access.choices = [
      .init(summary: summary(id: "standard", width: 1920, height: 1080, hiDPI: false), nativeIndex: 73),
      .init(summary: summary(id: "100Hz", width: 1920, height: 1080, hz: 100), nativeIndex: 114),
      .init(summary: summary(id: "VRR", width: 1920, height: 1080, kind: .variable), nativeIndex: 115),
    ]
    do {
      try await control(access).setMode(target, displayID: .max, identity: "monitor")
      Issue.record("A different density or refresh rate must not satisfy the request")
    } catch {
      #expect(error as? DisplayModeControlError == .unavailable)
    }
    #expect(access.writes.isEmpty)
  }

  @Test("A successful API return with unchanged output is reported as unconfirmed")
  func falseSuccess() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    access.updatesOutput = false
    let store = makeStore(access)
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    await store.apply(modeID: target.summary.id, to: display(access))?.value
    #expect(store.operationError == DisplayModeControlError.unconfirmed.rawValue)
    #expect(store.pendingChange == nil)
    #expect(!store.isChangingMode)
    #expect(access.actual?.width == 1024)
  }

  @Test("Readback waits for WindowServer to publish the changed mode")
  func delayedReadback() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    access.delayedReads = 2
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    try await control(access, attempts: 4).setMode(target.summary, displayID: .max, identity: "monitor")
    #expect(access.actual?.pixelWidth == 3840)
    #expect(access.writes.count == 1)
  }

  @Test("Equal geometry does not confirm an unchanged timing variant")
  func unchangedVariant() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let variant = DisplayModeChoice(summary: summary(id: "different-timing"), nativeIndex: 88)
    access.choices.append(variant)
    access.updatesOutput = false
    do {
      try await control(access).setMode(variant.summary, displayID: .max, identity: "monitor")
      Issue.record("Unchanged native mode ID must not confirm a distinct timing variant")
    } catch {
      #expect(error as? DisplayModeControlError == .unconfirmed)
    }
  }

  @Test("Readback accepts a mode ID rebuilt during configuration")
  func renumberedDuringConfiguration() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    let replacement = DisplayModeChoice(
      summary: summary(id: "rebuilt", width: 1920, height: 1080), nativeIndex: 213
    )
    access.onConfigure = { [weak access] _ in
      access?.choices = [replacement]
      access?.actual = replacement.summary
    }
    try await control(access).setMode(target.summary, displayID: .max, identity: "monitor")
    #expect(access.actual?.id == replacement.summary.id)
  }

  @Test("Readback rejects standard 1080p for a HiDPI request and restores the original output")
  func wrongDensityReadback() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let store = makeStore(access)
    let standard = summary(id: "wrong-output", width: 1920, height: 1080, hiDPI: false)
    access.onConfigure = { [weak access] choice in
      if choice.nativeIndex == 113 { access?.actual = standard }
    }
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    await store.apply(modeID: target.summary.id, to: display(access))?.value
    #expect(access.writes.map(\.nativeIndex) == [113, 23])
    #expect(access.actual?.width == 1024)
    #expect(store.pendingChange == nil)
    #expect(store.operationError == DisplayModeControlError.unconfirmed.rawValue)
  }

  @Test("Identity is rechecked after configuration before trusting readback")
  func disconnectDuringChange() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    access.onConfigure = { [weak access] _ in access?.connectedIdentity = "replacement" }
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    do {
      try await control(access).setMode(target.summary, displayID: .max, identity: "monitor")
      Issue.record("Readback from a replacement display cannot confirm the original request")
    } catch {
      #expect(error as? DisplayModeControlError == .disconnected)
    }
    #expect(access.writes.count == 1)
  }

  @Test("Failed restore retains the original mode for retry and has no automatic retry loop")
  func failedRestoreCanRetry() async throws {
    let access = try ControlledModeAccess(choices: catalog(startHiDPI: true))
    let store = makeStore(access)
    let low = try #require(access.choices.first { $0.nativeIndex == 23 })
    await store.apply(modeID: low.summary.id, to: display(access))?.value
    access.result = .failure
    await store.restorePendingChange()?.value
    #expect(store.pendingChange?.restoreFailed == true)
    #expect(store.pendingChange?.previousMode.pixelWidth == 3840)
    #expect(store.pendingChange?.secondsRemaining == 0)
    #expect(!store.isChangingMode)
    access.result = .success
    await store.restorePendingChange()?.value
    #expect(store.pendingChange == nil)
    #expect(access.actual?.pixelWidth == 3840)
    #expect(store.operationError == nil)
  }

  @Test("Keeping the current mode after a failed restore releases the controls")
  func dismissFailedRestore() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let store = makeStore(access)
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    await store.apply(modeID: target.summary.id, to: display(access))?.value
    access.result = .failure
    await store.restorePendingChange()?.value
    store.confirmPendingChange()
    #expect(store.pendingChange == nil)
    #expect(!store.isChangingMode)
  }

  @Test("Leaving during an in-flight switch restores after verification")
  func restoreWhileApplying() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let store = makeStore(access)
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    let task = store.apply(modeID: target.summary.id, to: display(access))
    #expect(store.isChangingMode)
    store.confirmPendingChange()
    #expect(store.pendingChange != nil)
    store.restorePendingChange()
    await task?.value
    #expect(access.writes.map(\.nativeIndex) == [113, 23])
    #expect(store.pendingChange == nil)
    #expect(!store.isChangingMode)
  }

  @Test("Timeout uses the same complete native catalog to restore the original HiDPI mode")
  func countdownRestore() async throws {
    let access = try ControlledModeAccess(choices: catalog(startHiDPI: true))
    let store = makeStore(access, seconds: 1)
    let low = try #require(access.choices.first { $0.nativeIndex == 23 })
    await store.apply(modeID: low.summary.id, to: display(access))?.value
    try await Task.sleep(for: .milliseconds(1200))
    #expect(access.writes.map(\.nativeIndex) == [23, 113])
    #expect(store.pendingChange == nil)
  }

  @Test("A reused display ID cannot receive a restore intended for the original monitor")
  func changedIdentity() async throws {
    let access = try ControlledModeAccess(choices: catalog())
    let store = makeStore(access)
    let target = try #require(access.choices.first { $0.nativeIndex == 113 })
    await store.apply(modeID: target.summary.id, to: display(access))?.value
    access.connectedIdentity = "replacement"
    await store.restorePendingChange()?.value
    #expect(access.writes.count == 1)
    #expect(store.pendingChange?.restoreFailed == true)
    store.confirmPendingChange()
    do {
      try await control(access).setMode(target.summary, displayID: .max, identity: "monitor")
      Issue.record("A reused display ID must not receive the old monitor's mode")
    } catch {
      #expect(error as? DisplayModeControlError == .disconnected)
    }
    #expect(access.writes.count == 1)
  }

  private func control(_ access: ControlledModeAccess, attempts: Int = 1) -> DisplayModeControl {
    .init(access: access, verificationAttempts: attempts, verificationDelay: .zero)
  }

  private func makeStore(_ access: ControlledModeAccess, seconds: Int = 15) -> DisplayControlStore {
    .init(displays: [display(access)], modeControl: control(access), confirmationSeconds: seconds)
  }

  private func display(_ access: ControlledModeAccess) -> DisplaySummary {
    .init(
      id: "test", displayID: .max, identity: "monitor", name: "27B35H",
      isBuiltIn: false, isMain: false, boundsWidth: 1920, boundsHeight: 1080,
      currentMode: access.actual, modes: access.choices.map(\.summary),
      colorProfile: "test", colorSpace: "test"
    )
  }

  private func catalog(startHiDPI: Bool = false) throws -> [DisplayModeChoice] {
    let native = try [
      (23, descriptor()),
      (73, descriptor(width: 1920, height: 1080, hiDPI: false, density: 1)),
      (113, descriptor(width: 1920, height: 1080)),
      (114, descriptor(width: 1920, height: 1080, hz: 100)),
    ].map { try #require(DisplayNativeMode(index: Int32($0.0), data: $0.1)) }
    var publicModes = [
      DisplayModeChoice(summary: summary(id: "io-low", current: !startHiDPI), nativeIndex: nil),
      DisplayModeChoice(summary: summary(id: "io-standard", width: 1920, height: 1080, hiDPI: false), nativeIndex: nil),
    ]
    if startHiDPI {
      publicModes.append(.init(summary: summary(id: "io-high", width: 1920, height: 1080, current: true), nativeIndex: nil))
    }
    return DisplayModeCatalog.merge(
      publicModes: publicModes, nativeModes: native,
      publicIndices: ["io-low": 23, "io-standard": 73],
      currentIndex: startHiDPI ? 113 : 23, kind: { _ in .fixed }
    )
  }

  private func summary(
    id: String, width: Int = 1024, height: Int = 576, hz: Double = 120,
    hiDPI: Bool = true, current: Bool = false, kind: DisplayRefreshKind = .fixed
  ) -> DisplayModeSummary {
    .init(
      id: id, width: width, height: height,
      pixelWidth: width * (hiDPI ? 2 : 1), pixelHeight: height * (hiDPI ? 2 : 1),
      refreshRate: hz, refreshKind: kind, isHiDPI: hiDPI, isCurrent: current
    )
  }

  private func descriptor(
    width: UInt32 = 1024, height: UInt32 = 576, hz: UInt16 = 120,
    hiDPI: Bool = true, density: Float = 2, flags: UInt32 = 3
  ) -> Data {
    var data = Data(repeating: 0, count: 212)
    func put<T>(_ value: T, at offset: Int) {
      withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
    }
    put(UInt32(900), at: 0) // Deliberately different from the query index and I/O ID.
    put(flags, at: 4)
    put(width, at: 8)
    put(height, at: 12)
    put(hz, at: 190)
    put(width * (hiDPI ? 2 : 1), at: 200)
    put(height * (hiDPI ? 2 : 1), at: 204)
    put(density, at: 208)
    return data
  }
}

@MainActor
private final class ControlledModeAccess: DisplayModeAccessing {
  var choices: [DisplayModeChoice]
  var actual: DisplayModeSummary?
  var connectedIdentity: String? = "monitor"
  var writes: [DisplayModeChoice] = []
  var result = CGError.success
  var updatesOutput = true
  var delayedReads = 0
  var onConfigure: ((DisplayModeChoice) -> Void)?
  private var delayedOutput: DisplayModeSummary?

  init(choices: [DisplayModeChoice]) throws {
    self.choices = choices
    actual = try #require(choices.first { $0.summary.isCurrent })?.summary
  }

  func identity(_ displayID: UInt32) -> String? { displayID == .max ? connectedIdentity : nil }
  func modes(_ displayID: UInt32) -> [DisplayModeChoice] { choices }
  func currentMode(_ displayID: UInt32) -> DisplayModeSummary? {
    if let delayedOutput {
      if delayedReads == 0 {
        actual = delayedOutput
        self.delayedOutput = nil
      } else { delayedReads -= 1 }
    }
    return actual
  }

  func configure(_ choice: DisplayModeChoice, displayID: UInt32) -> CGError {
    writes.append(choice)
    if result == .success, updatesOutput {
      if delayedReads > 0 { delayedOutput = choice.summary }
      else { actual = choice.summary }
    }
    onConfigure?(choice)
    return result
  }
}
