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
  let previousModeID: String
  let appliedModeID: String
  var secondsRemaining: Int
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
  @Published var operationError: String?
  @Published private(set) var hardware: [String: DisplayHardwareSnapshot] = [:]
  @Published private(set) var colorConfigurations: [String: DisplayColorConfiguration] = [:]
  @Published private(set) var busyDisplays: Set<String> = []
  @Published private(set) var adjustmentTargets: [DisplayAdjustmentKey: Double] = [:]
  @Published private(set) var adjustingControls: Set<DisplayAdjustmentKey> = []
  @Published private(set) var revision = 0

  private var rollbackTask: Task<Void, Never>?
  private var previousSystemMode: CGDisplayMode?
  private var pendingIdentity: String?
  private let system = DisplaySystemInterfaces()
  private let hardwareControl: any DisplayHardwareControlling
  private var adjustmentTasks: [DisplayAdjustmentKey: Task<Void, Never>] = [:]
  private var pendingAdjustments: [DisplayAdjustmentKey: Double] = [:]
  private var hardwareRevisions: [String: Int] = [:]

  init(displays: [DisplaySummary] = [], hardwareControl: any DisplayHardwareControlling = DisplayHardwareControl()) {
    self.displays = displays
    self.hardwareControl = hardwareControl
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
      guard let identity = DisplayColorProfiles.identity(displayID) else { return nil }
      let current = CGDisplayCopyDisplayMode(displayID)
      let currentKey = current.map(Self.modeKey)
      let screenColorSpace = screen?.colorSpace
      let colorSpace = screenColorSpace.map {
        "\($0.numberOfColorComponents)-component"
      } ?? "Unavailable"
      let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
      var rawModes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? [])
      if let current, !rawModes.contains(where: { Self.modeKey($0) == currentKey }) {
        rawModes.append(current)
      }
      let refreshKinds = system.refreshKinds(displayID)
      let modes = rawModes.map { mode in
          DisplayModeSummary(
            id: Self.modeKey(mode),
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            refreshKind: refreshKinds[mode.ioDisplayModeID] ?? .unknown,
            isHiDPI: mode.pixelWidth > mode.width || mode.pixelHeight > mode.height,
            isCurrent: currentKey == Self.modeKey(mode)
          )
        }
        .sorted {
          if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
          if $0.width != $1.width { return $0.width > $1.width }
          if $0.height != $1.height { return $0.height > $1.height }
          if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
          return $0.pixelWidth > $1.pixelWidth
        }

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

  func apply(modeID: String, to display: DisplaySummary) {
    guard pendingChange == nil, !busyDisplays.contains(display.id), !isAdjusting(display) else { return }
    guard DisplayColorProfiles.identity(display.displayID) == display.identity,
      let previousMode = CGDisplayCopyDisplayMode(display.displayID) else {
      operationError = "The current display mode could not be identified."
      return
    }
    guard Self.modeKey(previousMode) != modeID else { return }
    guard let targetMode = Self.systemMode(displayID: display.displayID, id: modeID) else {
      operationError = "The selected display mode is no longer available."
      refresh()
      return
    }

    let result = CGDisplaySetDisplayMode(display.displayID, targetMode, nil)
    guard result == .success else {
      operationError = "macOS rejected this display mode."
      return
    }

    let change = DisplayModeChange(
      id: UUID(),
      displayID: display.displayID,
      previousModeID: Self.modeKey(previousMode),
      appliedModeID: modeID,
      secondsRemaining: 15
    )
    pendingChange = change
    previousSystemMode = previousMode
    pendingIdentity = display.identity
    rollbackTask?.cancel()
    rollbackTask = Task { [weak self] in
      for remaining in stride(from: 14, through: 0, by: -1) {
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
    refresh()
  }

  func confirmPendingChange() {
    rollbackTask?.cancel()
    rollbackTask = nil
    pendingChange = nil
    previousSystemMode = nil
    pendingIdentity = nil
    refresh()
  }

  func restorePendingChange() {
    guard let change = pendingChange else { return }
    rollbackTask?.cancel()
    rollbackTask = nil

    if DisplayColorProfiles.identity(change.displayID) == pendingIdentity,
      let previousMode = previousSystemMode {
      if CGDisplaySetDisplayMode(change.displayID, previousMode, nil) != .success {
        operationError = "macOS could not restore the previous display mode."
      }
    }
    pendingChange = nil
    previousSystemMode = nil
    pendingIdentity = nil
    refresh()
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

  private static func systemMode(displayID: UInt32, id: String) -> CGDisplayMode? {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode])?
      .first { modeKey($0) == id }
  }

  private static func modeKey(_ mode: CGDisplayMode) -> String {
    let refresh = Int((mode.refreshRate * 100).rounded())
    // A display can expose duplicate geometry and refresh combinations with
    // different I/O mode IDs (for example, different timing/color variants).
    // Keep the system ID in the key so every mode remains selectable.
    return "\(mode.ioDisplayModeID)-\(mode.width)-\(mode.height)-\(mode.pixelWidth)-\(mode.pixelHeight)-\(refresh)"
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
      SystemToolPageHeader(destination: .displays)

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
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          displayIdentity(display)
          currentModeSection(display)
          Divider()
          supportedModesSection(display)
          Divider()
          DisplayAdjustmentsView(store: store, display: display)
            .id(display.id)
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
      }

      if let pendingChange = store.pendingChange,
        let changedDisplay = store.displays.first(where: { $0.displayID == pendingChange.displayID }),
        let appliedMode = changedDisplay.modes.first(where: { $0.id == pendingChange.appliedModeID })
      {
        modeChangeOverlay(appliedMode, secondsRemaining: pendingChange.secondsRemaining)
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
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

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
          Text(display.name).font(.title2.weight(.semibold)).lineLimit(1)
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
    return VStack(alignment: .leading, spacing: 0) {
      if let mode = display.currentMode {
        HStack(alignment: .top, spacing: 0) {
          metric("Resolution", value: mode.resolutionLabel, detail: mode.isHiDPI ? "HiDPI" : nil)
          Divider().frame(height: 44)
          metric("Pixel Resolution", value: mode.pixelResolutionLabel, detail: nil)
          Divider().frame(height: 44)
          metric("Refresh Rate", value: mode.refreshLabel, detail: nil)
        }
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

  private func modeChangeOverlay(
    _ mode: DisplayModeSummary,
    secondsRemaining: Int
  ) -> some View {
    ZStack {
      Color.black.opacity(0.18)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 14) {
        Label("Confirm Display Mode", systemImage: "rectangle.on.rectangle")
          .font(.headline)

        Text(localized(
          "The display is using %@ at %@. Keep this mode if the screen looks correct.",
          mode.resolutionLabel,
          mode.refreshLabel
        ))
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Text(localized("Restoring previous mode in %llds", Int64(secondsRemaining)))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Spacer(minLength: 12)
          Button("Restore") {
            store.restorePendingChange()
          }
          Button("Keep Mode") {
            store.confirmPendingChange()
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)
      .frame(maxWidth: 460)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
    .zIndex(2)
  }

  private func metric(_ title: LocalizedStringKey, value: String, detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.body.weight(.medium))
        .monospacedDigit()
      if let detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.tint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
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
