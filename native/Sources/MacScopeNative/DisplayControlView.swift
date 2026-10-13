import AppKit
import CoreGraphics
import SwiftUI

struct DisplayModeSummary: Identifiable, Hashable, Sendable {
  let id: String
  let width: Int
  let height: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let refreshRate: Double
  let refreshKind: DisplayRefreshKind
  let isHiDPI: Bool
  let isCurrent: Bool
  var isRefreshRateTruncated = false

  func matches(_ other: DisplayModeSummary) -> Bool {
    guard width == other.width, height == other.height,
      pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
      isHiDPI == other.isHiDPI,
      refreshKind == other.refreshKind || refreshKind == .unknown || other.refreshKind == .unknown,
      refreshRate.isFinite, other.refreshRate.isFinite else { return false }
    // SkyLight's legacy descriptor truncates Hz to an integer. Preserve the
    // precise CoreGraphics rate whenever one is available, without dropping
    // the hidden native mode solely because its descriptor has less precision.
    if isRefreshRateTruncated || other.isRefreshRateTruncated {
      return floor(refreshRate) == floor(other.refreshRate)
    }
    return abs(refreshRate - other.refreshRate) < 0.02
  }

  var resolutionLabel: String {
    "\(width) × \(height)"
  }

  var pixelResolutionLabel: String {
    "\(pixelWidth) × \(pixelHeight)"
  }

  var aspectRatioLabel: String {
    guard width > 0, height > 0 else { return "-" }
    for (x, y) in [(16, 9), (16, 10), (4, 3), (3, 2), (5, 4), (21, 9), (32, 9), (9, 16), (10, 16)] {
      if width * y == height * x { return "\(x):\(y)" }
    }
    return String(format: "≈%.2f:1", Double(width) / Double(height))
  }

  func aspectRatioLabel(isBuiltIn: Bool) -> String {
    guard isBuiltIn, width > 0, height > 0 else { return aspectRatioLabel }
    let ratio = Double(width) / Double(height)
    // Scaled modes round to whole pixels; allow that rounding around the
    // full-height aspect ratios of the notched MacBook panels.
    let notchRatios = [3024.0 / 1964, 3456.0 / 2234, 2560.0 / 1664, 2880.0 / 1864]
    return notchRatios.contains { abs(ratio - $0) < 0.002 } ? "Notch" : aspectRatioLabel
  }

  var refreshLabel: String {
    if refreshKind == .proMotion { return "ProMotion" }
    if refreshKind == .variable { return "VRR (\(frequencyLabel))" }
    return frequencyLabel
  }

  var frequencyLabel: String {
    guard refreshRate.isFinite, refreshRate > 0 else { return "-" }
    let rate = (refreshRate * 100).rounded() / 100
    return String(format: rate == rate.rounded() ? "%.0f Hz" : "%.2f Hz", rate)
  }
}

struct DisplayModeFilter: Equatable {
  var resolution = ""
  var density = ""
  var refreshKind = ""
  var frequency = ""

  func matches(_ mode: DisplayModeSummary) -> Bool {
    (resolution.isEmpty || resolution == mode.resolutionLabel)
      && (density.isEmpty || (density == "HiDPI") == mode.isHiDPI)
      && (refreshKind.isEmpty || refreshKind == mode.refreshKind.rawValue)
      && (frequency.isEmpty || frequency == mode.frequencyLabel)
  }

  static func current(_ mode: DisplayModeSummary?) -> Self {
    guard let mode else { return .init() }
    return .init(density: mode.isHiDPI ? "HiDPI" : "Standard")
  }
}

struct DisplaySummary: Identifiable, Hashable, Sendable {
  let id: String
  let displayID: UInt32
  let identity: String
  let name: String
  let isBuiltIn: Bool
  let isMain: Bool
  let boundsWidth: Int
  let boundsHeight: Int
  let currentMode: DisplayModeSummary?
  let modes: [DisplayModeSummary]
  let colorProfile: String
  let colorSpace: String

  var connectionLabel: String {
    isBuiltIn ? "Built-in" : "External"
  }
}

struct DisplayModeChange: Identifiable, Sendable {
  let id: UUID
  let displayID: UInt32
  let identity: String
  let previousMode: DisplayModeSummary
  let appliedMode: DisplayModeSummary
  var secondsRemaining: Int
  var restoreFailed = false
}

struct DisplayAdjustmentKey: Hashable {
  let displayID: String
  let feature: DDCFeature?
}

@MainActor
final class DisplayControlStore: ObservableObject {
  @Published private(set) var displays: [DisplaySummary] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage = ""
  @Published private(set) var pendingChange: DisplayModeChange?
  @Published private(set) var isChangingMode = false
  @Published var operationError: String?
  @Published private(set) var hardware: [String: DisplayHardwareSnapshot] = [:]
  @Published private(set) var colorConfigurations: [String: DisplayColorConfiguration] = [:]
  @Published private(set) var busyDisplays: Set<String> = []
  @Published private(set) var adjustmentTargets: [DisplayAdjustmentKey: Double] = [:]
  @Published private(set) var adjustingControls: Set<DisplayAdjustmentKey> = []
  @Published private(set) var revision = 0

  private var rollbackTask: Task<Void, Never>?
  private var modeTask: Task<Void, Never>?
  private var isRestoringMode = false
  private var restoreAfterApply = false
  private let modeControl: DisplayModeControl
  private let confirmationSeconds: Int
  private let hardwareControl: any DisplayHardwareControlling
  private var adjustmentTasks: [DisplayAdjustmentKey: Task<Void, Never>] = [:]
  private var pendingAdjustments: [DisplayAdjustmentKey: Double] = [:]
  private var hardwareRevisions: [String: Int] = [:]

  init(
    displays: [DisplaySummary] = [],
    hardwareControl: any DisplayHardwareControlling = DisplayHardwareControl(),
    modeControl: DisplayModeControl = DisplayModeControl(), confirmationSeconds: Int = 15
  ) {
    self.displays = displays
    self.hardwareControl = hardwareControl
    self.modeControl = modeControl
    self.confirmationSeconds = max(1, confirmationSeconds)
  }

  func isAdjusting(_ display: DisplaySummary) -> Bool {
    adjustingControls.contains { $0.displayID == display.id }
  }

  func percent(for feature: DDCFeature?, display: DisplaySummary) -> Double? {
    adjustmentTargets[.init(displayID: display.id, feature: feature)]
      ?? hardware[display.id]?.percent(for: feature)
  }

  func refresh() {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = ""

    let result = readDisplays()
    displays = result.displays
    errorMessage = result.errorMessage
    isLoading = false
    revision += 1
  }

  private func readDisplays() -> (displays: [DisplaySummary], errorMessage: String) {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    let error = CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    guard error == .success else {
      return ([], "Unable to read the active display list.")
    }

    let screensByID: [UInt32: NSScreen] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { return nil }
      return (number.uint32Value, screen)
    })

    let summaries = ids.prefix(Int(count)).compactMap { displayID -> DisplaySummary? in
      let screen = screensByID[displayID]
      guard let identity = modeControl.identity(displayID) else { return nil }
      let screenColorSpace = screen?.colorSpace
      let colorSpace = screenColorSpace.map {
        "\($0.numberOfColorComponents)-component"
      } ?? "Unavailable"
      let modes = modeControl.modes(displayID)

      let currentSummary = modes.first(where: \.isCurrent)
      let bounds = CGDisplayBounds(displayID)
      return DisplaySummary(
        id: "\(displayID)-\(identity)",
        displayID: displayID,
        identity: identity,
        name: screen?.localizedName ?? "Display \(displayID)",
        isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
        isMain: CGDisplayIsMain(displayID) != 0,
        boundsWidth: Int(bounds.width),
        boundsHeight: Int(bounds.height),
        currentMode: currentSummary,
        modes: modes,
        colorProfile: screenColorSpace?.localizedName ?? "Unavailable",
        colorSpace: colorSpace
      )
    }

    return (summaries, "")
  }

  @discardableResult
  func apply(modeID: String, to display: DisplaySummary) -> Task<Void, Never>? {
    guard pendingChange == nil, !isChangingMode,
      !busyDisplays.contains(display.id), !isAdjusting(display) else { return nil }
    guard modeControl.identity(display.displayID) == display.identity,
      let previousMode = modeControl.currentMode(display.displayID) else {
      operationError = "The current display mode could not be identified."
      return nil
    }
    guard previousMode.id != modeID else { return nil }
    guard let targetMode = display.modes.first(where: { $0.id == modeID }) else {
      operationError = "The selected display mode is no longer available."
      refresh()
      return nil
    }

    let change = DisplayModeChange(
      id: UUID(),
      displayID: display.displayID,
      identity: display.identity, previousMode: previousMode, appliedMode: targetMode,
      secondsRemaining: confirmationSeconds
    )
    pendingChange = change
    operationError = nil
    isChangingMode = true
    restoreAfterApply = false
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.modeControl.setMode(targetMode, displayID: display.displayID, identity: display.identity)
        self.isChangingMode = false
        if self.restoreAfterApply {
          await self.restorePendingChange()?.value
        } else {
          self.startRollbackCountdown(change)
        }
      } catch {
        self.isChangingMode = false
        self.operationError = error.localizedDescription
        if self.modeControl.currentMode(display.displayID)?.matches(previousMode) == true {
          self.clearPendingChange()
        } else {
          await self.restorePendingChange()?.value
        }
      }
      self.refresh()
    }
    modeTask = task
    return task
  }

  private func startRollbackCountdown(_ change: DisplayModeChange) {
    rollbackTask?.cancel()
    rollbackTask = Task { [weak self] in
      for remaining in stride(from: change.secondsRemaining - 1, through: 0, by: -1) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        guard let self, self.pendingChange?.id == change.id else { return }
        if remaining == 0 {
          self.restorePendingChange()
          return
        }
        self.pendingChange?.secondsRemaining = remaining
      }
    }
  }

  func confirmPendingChange() {
    guard !isChangingMode else { return }
    clearPendingChange()
    refresh()
  }

  private func clearPendingChange() {
    rollbackTask?.cancel()
    rollbackTask = nil
    pendingChange = nil
    restoreAfterApply = false
  }

  @discardableResult
  func restorePendingChange() -> Task<Void, Never>? {
    guard let change = pendingChange else { return nil }
    if isChangingMode {
      if !isRestoringMode { restoreAfterApply = true }
      return modeTask
    }
    rollbackTask?.cancel()
    rollbackTask = nil
    if operationError == "macOS could not restore the previous display mode." { operationError = nil }
    pendingChange?.secondsRemaining = 0
    pendingChange?.restoreFailed = false
    isChangingMode = true
    isRestoringMode = true
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.modeControl.setMode(change.previousMode, displayID: change.displayID, identity: change.identity)
        self.clearPendingChange()
      } catch {
        self.pendingChange?.restoreFailed = true
        self.operationError = "macOS could not restore the previous display mode."
      }
      self.isRestoringMode = false
      self.isChangingMode = false
      self.refresh()
    }
    modeTask = task
    return task
  }

  func loadControls(_ display: DisplaySummary) async {
    guard !busyDisplays.contains(display.id), !isAdjusting(display) else { return }
    let hardwareRevision = hardwareRevisions[display.id, default: 0]
    busyDisplays.insert(display.id)
    defer { busyDisplays.remove(display.id) }
    let colors = await hardwareControl.colorConfiguration(display.displayID)
    let controls = await hardwareControl.read(
      displayID: display.displayID, identity: display.identity, builtIn: display.isBuiltIn
    )
    guard displays.contains(where: { $0.id == display.id }) else { return }
    colorConfigurations[display.id] = colors
    // A refresh started before a drag must not replace a newer requested value.
    guard hardwareRevisions[display.id, default: 0] == hardwareRevision else { return }
    for key in adjustmentTargets.keys.filter({ $0.displayID == display.id }) {
      let previous = hardware[display.id]?.percent(for: key.feature)
      let actual = controls.percent(for: key.feature)
      if previous != actual { adjustmentTargets.removeValue(forKey: key) }
    }
    hardware[display.id] = controls
  }

  @discardableResult
  func setBrightness(_ value: Double, feature: DDCFeature?, display: DisplaySummary) -> Task<Void, Never>? {
    guard value.isFinite, pendingChange == nil,
      displays.contains(where: { $0.id == display.id }),
      hardware[display.id]?.percent(for: feature) != nil else { return nil }
    let key = DisplayAdjustmentKey(displayID: display.id, feature: feature)
    let target = min(100, max(0, value)).rounded()
    guard target != percent(for: feature, display: display) else { return adjustmentTasks[key] }
    adjustmentTargets[key] = target
    pendingAdjustments[key] = target
    hardwareRevisions[display.id, default: 0] += 1
    if let task = adjustmentTasks[key] { return task }
    adjustingControls.insert(key)
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.writeAdjustments(key, display: display)
    }
    adjustmentTasks[key] = task
    return task
  }

  private func writeAdjustments(_ key: DisplayAdjustmentKey, display: DisplaySummary) async {
    defer {
      adjustmentTasks.removeValue(forKey: key)
      pendingAdjustments.removeValue(forKey: key)
      adjustingControls.remove(key)
    }
    while pendingAdjustments[key] != nil {
      // Throttle hardware writes while keeping every UI change synchronous.
      try? await Task.sleep(nanoseconds: key.feature == nil ? 80_000_000 : 120_000_000)
      guard !Task.isCancelled, displays.contains(where: { $0.id == display.id }),
        let target = pendingAdjustments.removeValue(forKey: key) else { return }
      do {
        if let feature = key.feature {
          let actual = try await hardwareControl.setDDC(
            feature, percent: target, displayID: display.displayID, identity: display.identity
          )
          if let previous = hardware[display.id] {
            var ddc = previous.ddc
            ddc[feature] = actual
            hardware[display.id] = .init(brightness: previous.brightness, ddc: ddc, error: previous.error)
          }
        } else {
          let actual = try await hardwareControl.setNativeBrightness(
            target, displayID: display.displayID, identity: display.identity
          )
          if let previous = hardware[display.id] {
            hardware[display.id] = .init(brightness: actual, ddc: previous.ddc, error: previous.error)
          }
        }
      } catch {
        // Only the latest request may roll back the UI or present an error.
        if pendingAdjustments[key] == nil {
          adjustmentTargets.removeValue(forKey: key)
          if displays.contains(where: { $0.id == display.id }) { operationError = error.localizedDescription }
        }
      }
    }
  }

  func setProfile(_ id: String, display: DisplaySummary) async {
    guard !busyDisplays.contains(display.id), pendingChange == nil else { return }
    busyDisplays.insert(display.id)
    defer { busyDisplays.remove(display.id) }
    do {
      colorConfigurations[display.id] = try await hardwareControl.setProfile(
        id, displayID: display.displayID, identity: display.identity
      )
    } catch { operationError = error.localizedDescription }
    colorConfigurations[display.id] = await hardwareControl.colorConfiguration(display.displayID)
  }

}

struct DisplayControlView: View {
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var store: DisplayControlStore
  @State private var selectedDisplayID: String?
  @State private var selectedModeID: String?
  @State private var modeFilter = DisplayModeFilter()

  init(store: DisplayControlStore = DisplayControlStore()) {
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    VStack(spacing: 0) {
      if store.isLoading {
        ProgressView("Loading Displays")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.displays.isEmpty {
        SystemToolEmptyView(
          systemImage: "display.2",
          title: "No Displays Available",
          message: "MacScope could not read any active displays."
        ) {
          Button("Refresh", action: store.refresh)
            .buttonStyle(.borderedProminent)
        }
      } else {
        displayWorkspace
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: store.refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh")
        .disabled(store.isLoading)
      }
    }
    .alert(
      "Unable to Change Display Settings",
      isPresented: Binding(
        get: { store.operationError != nil },
        set: { if !$0 { store.operationError = nil } }
      )
    ) {
      Button("OK") { store.operationError = nil }
    } message: {
      Text(localized(store.operationError ?? ""))
    }
    .onAppear {
      if store.displays.isEmpty {
        store.refresh()
      }
      if selectedDisplayID == nil {
        selectedDisplayID = store.displays.first?.id
        selectedModeID = store.displays.first?.currentMode?.id
        modeFilter = .current(store.displays.first?.currentMode)
      }
    }
    .onChange(of: store.displays) { displays in
      guard let selectedDisplayID else {
        self.selectedDisplayID = displays.first?.id
        return
      }
      if !displays.contains(where: { $0.id == selectedDisplayID }) {
        self.selectedDisplayID = displays.first?.id
      }
      if store.pendingChange == nil {
        selectedModeID = displays.first(where: { $0.id == self.selectedDisplayID })?.currentMode?.id
      }
    }
    .onChange(of: selectedDisplayID) { displayID in
      selectedModeID = store.displays.first(where: { $0.id == displayID })?.currentMode?.id
      modeFilter = .current(selectedDisplay?.currentMode)
    }
    .onChange(of: modeFilter) { _ in
      guard let display = selectedDisplay else { return }
      let modes = display.modes.filter(modeFilter.matches)
      if !modes.contains(where: { $0.id == selectedModeID }) {
        selectedModeID = modes.first?.id
      }
    }
    .task(id: "\(selectedDisplay?.id ?? "")-\(store.revision)") {
      if let display = selectedDisplay { await store.loadControls(display) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      store.refresh()
    }
    .onDisappear {
      store.restorePendingChange()
    }
  }

  private var displayWorkspace: some View {
    Group {
      if let selectedDisplay {
        displayDetail(selectedDisplay)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "display")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.secondary)
          Text("Select a Display")
            .font(.headline)
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var selectedDisplay: DisplaySummary? {
    store.displays.first { $0.id == selectedDisplayID } ?? store.displays.first
  }

  private func displayDetail(_ display: DisplaySummary) -> some View {
    ZStack {
      Form {
        Section {
          displayIdentity(display)
          currentModeSection(display)
        }
        Section {
          supportedModesSection(display)
        }
        DisplayAdjustmentsView(store: store, display: display)
          .id(display.id)
      }
      .formStyle(.grouped)
      .frame(maxWidth: 1040)
      .frame(maxWidth: .infinity)
      .compactNativeScrollers()

      if let pendingChange = store.pendingChange {
        modeChangeOverlay(pendingChange)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func displayIdentity(_ display: DisplaySummary) -> some View {
    HStack(spacing: 14) {
      Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(.tint)
        .frame(width: 56, height: 56)

      VStack(alignment: .leading, spacing: 5) {
        Menu {
          Picker("Select a Display", selection: Binding(
            get: { selectedDisplayID ?? display.id }, set: { selectedDisplayID = $0 }
          )) {
            ForEach(store.displays) { item in
              Label(item.name, systemImage: item.isBuiltIn ? "laptopcomputer" : "display")
                .tag(item.id)
            }
          }
        } label: {
          Text(display.name).font(.headline).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Select a Display")
        .disabled(store.pendingChange != nil)
        HStack(spacing: 6) {
          statusBadgeText(
            localized(display.isBuiltIn ? "Built-in" : "External"),
            systemImage: display.isBuiltIn ? "laptopcomputer" : "cable.connector"
          )
          if display.isMain {
            statusBadge("Main Display", systemImage: "checkmark.circle.fill")
          }
          if display.modes.contains(where: { $0.refreshKind == .proMotion }) {
            statusBadge("ProMotion", systemImage: "waveform.path")
          }
        }
      }

      Spacer(minLength: 0)
    }
  }

  private func currentModeSection(_ display: DisplaySummary) -> some View {
    return Group {
      if let mode = display.currentMode {
        LabeledContent("Resolution") {
          Text(mode.resolutionLabel + (mode.isHiDPI ? " · HiDPI" : ""))
        }
        LabeledContent("Pixel Resolution", value: mode.pixelResolutionLabel)
        LabeledContent("Refresh Rate", value: mode.refreshLabel)
      } else {
        unavailableText("Current display mode is unavailable.")
      }
    }
  }

  private func supportedModesSection(_ display: DisplaySummary) -> some View {
    let modes = display.modes.filter(modeFilter.matches)

    return VStack(alignment: .leading, spacing: 12) {
      DisplayModeSelectionView(display: display, filter: $modeFilter, selection: $selectedModeID)

      HStack {
        if let mode = modes.first(where: { $0.id == selectedModeID }) {
          Text("\(mode.resolutionLabel) · \(mode.refreshLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer()
        Button("Apply Mode") {
          guard let selectedModeID else { return }
          store.apply(modeID: selectedModeID, to: display)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          store.pendingChange != nil
            || store.busyDisplays.contains(display.id)
            || store.isAdjusting(display)
            || selectedModeID == nil
            || selectedModeID == display.currentMode?.id
            || !modes.contains(where: { $0.id == selectedModeID })
        )
      }
    }
    .disabled(store.pendingChange != nil)
  }

  private func modeChangeOverlay(_ change: DisplayModeChange) -> some View {
    ZStack {
      Color.black.opacity(0.18)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 14) {
        Label("Confirm Display Mode", systemImage: "rectangle.on.rectangle")
          .font(.headline)

        Group {
          if store.isChangingMode {
            Text("Changing Display Mode")
          } else if change.restoreFailed {
            Text("The previous mode could not be restored. You can retry or keep the current mode.")
          } else {
            Text(localized(
              "The display is using %@ at %@. Keep this mode if the screen looks correct.",
              change.appliedMode.resolutionLabel,
              change.appliedMode.refreshLabel
            ))
          }
        }
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Group {
            if store.isChangingMode {
              ProgressView().controlSize(.small)
            } else if !change.restoreFailed {
              Text(localized("Restoring previous mode in %llds", Int64(change.secondsRemaining)))
            }
          }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Spacer(minLength: 12)
          Button("Restore") {
            store.restorePendingChange()
          }
          .fixedSize()
          Button("Keep Mode") {
            store.confirmPendingChange()
          }
          .buttonStyle(.borderedProminent)
          .fixedSize()
        }
        .disabled(store.isChangingMode)
      }
      .padding(20)
      .frame(maxWidth: 460)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
    .zIndex(2)
  }

  private func statusBadge(_ title: LocalizedStringKey, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
  }

  private func statusBadgeText(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
  }

  private func unavailableText(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
