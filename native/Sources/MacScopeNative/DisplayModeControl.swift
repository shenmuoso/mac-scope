import CoreGraphics
import Foundation

struct DisplayNativeMode {
  // SkyLight's 212-byte mode description. The pixel dimensions at 200/204
  // matter: logical size alone cannot distinguish HiDPI from standard modes.
  static let byteCount = 0xD4
  let index: Int32
  let width: Int
  let height: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let refreshRate: Double

  init?(index: Int32, data: Data) {
    guard index >= 0, data.count >= Self.byteCount else { return nil }
    func value<T>(_ offset: Int, _: T.Type) -> T {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
    guard value(4, UInt32.self) & 0x4000_0000 == 0 else { return nil }
    width = Int(value(8, UInt32.self))
    height = Int(value(12, UInt32.self))
    pixelWidth = Int(value(200, UInt32.self))
    pixelHeight = Int(value(204, UInt32.self))
    let density = Double(value(208, Float.self))
    guard [width, height, pixelWidth, pixelHeight].allSatisfy({ (1...65536).contains($0) }),
      density.isFinite, density > 0, density <= 8,
      abs(Double(pixelWidth) - Double(width) * density) <= 1,
      abs(Double(pixelHeight) - Double(height) * density) <= 1 else { return nil }
    self.index = index
    refreshRate = Double(value(190, UInt16.self))
  }

  func summary(kind: DisplayRefreshKind, isCurrent: Bool) -> DisplayModeSummary {
    .init(
      id: "native-\(index)-\(width)-\(height)-\(pixelWidth)-\(pixelHeight)-\(Int(refreshRate))",
      width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      refreshRate: refreshRate, refreshKind: kind,
      isHiDPI: pixelWidth > width || pixelHeight > height, isCurrent: isCurrent,
      isRefreshRateTruncated: true
    )
  }
}

struct DisplayModeChoice {
  var summary: DisplayModeSummary
  let nativeIndex: Int32?
  var systemMode: CGDisplayMode? = nil
}

enum DisplayModeCatalog {
  static func merge(
    publicModes: [DisplayModeChoice], nativeModes: [DisplayNativeMode],
    publicIndices: [String: Int32], currentIndex: Int32?,
    kind: (Int32) -> DisplayRefreshKind
  ) -> [DisplayModeChoice] {
    var consumed: Set<String> = []
    var choices = nativeModes.map { native in
      var summary = native.summary(kind: kind(native.index), isCurrent: false)
      // Only the explicit mapping (or current-index query) relates the two
      // namespaces. An I/O mode ID is not necessarily a SkyLight mode index.
      let refinement = publicModes.first {
        (publicIndices[$0.summary.id] == native.index
          || ($0.summary.isCurrent && currentIndex == native.index))
          && summary.matches($0.summary)
      }
      if let refinement {
        consumed.insert(refinement.summary.id)
        summary = .init(
          id: summary.id, width: summary.width, height: summary.height,
          pixelWidth: summary.pixelWidth, pixelHeight: summary.pixelHeight,
          refreshRate: refinement.summary.refreshRate, refreshKind: summary.refreshKind,
          isHiDPI: summary.isHiDPI,
          isCurrent: currentIndex == native.index && refinement.summary.isCurrent
        )
      }
      return DisplayModeChoice(summary: summary, nativeIndex: native.index, systemMode: refinement?.systemMode)
    }
    choices.append(contentsOf: publicModes.filter { !consumed.contains($0.summary.id) })
    return choices.sorted {
      let lhs = $0.summary, rhs = $1.summary
      if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
      if lhs.width != rhs.width { return lhs.width > rhs.width }
      if lhs.height != rhs.height { return lhs.height > rhs.height }
      if lhs.refreshRate != rhs.refreshRate { return lhs.refreshRate > rhs.refreshRate }
      if lhs.pixelWidth != rhs.pixelWidth { return lhs.pixelWidth > rhs.pixelWidth }
      return lhs.id < rhs.id
    }
  }

  static func resolve(_ requested: DisplayModeSummary, in choices: [DisplayModeChoice]) -> DisplayModeChoice? {
    choices.first { $0.summary.id == requested.id && $0.summary.matches(requested) }
      ?? choices.first { $0.summary.matches(requested) }
  }
}

@MainActor
protocol DisplayModeAccessing {
  func identity(_ displayID: UInt32) -> String?
  func modes(_ displayID: UInt32) -> [DisplayModeChoice]
  func currentMode(_ displayID: UInt32) -> DisplayModeSummary?
  func configure(_ choice: DisplayModeChoice, displayID: UInt32) -> CGError
}

@MainActor
final class NativeDisplayModeAccess: DisplayModeAccessing {
  private let system = DisplaySystemInterfaces()

  func identity(_ displayID: UInt32) -> String? { DisplayColorProfiles.identity(displayID) }

  func modes(_ displayID: UInt32) -> [DisplayModeChoice] {
    let current = CGDisplayCopyDisplayMode(displayID)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    var publicModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
    if let current, !publicModes.contains(where: { Self.key($0) == Self.key(current) }) {
      publicModes.append(current)
    }
    let indices = system.nativeModeIndices(displayID)
    let publicChoices = publicModes.map { mode in
      DisplayModeChoice(
        summary: .init(
          id: Self.key(mode), width: mode.width, height: mode.height,
          pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
          refreshRate: mode.refreshRate,
          refreshKind: indices[mode.ioDisplayModeID].map { system.refreshKind(displayID, index: $0) } ?? .unknown,
          isHiDPI: mode.pixelWidth > mode.width || mode.pixelHeight > mode.height,
          isCurrent: current.map(Self.key) == Self.key(mode)
        ),
        nativeIndex: nil, systemMode: mode
      )
    }
    let publicIndices = Dictionary(uniqueKeysWithValues: publicModes.compactMap { mode in
      indices[mode.ioDisplayModeID].map { (Self.key(mode), $0) }
    })
    return DisplayModeCatalog.merge(
      publicModes: publicChoices, nativeModes: system.nativeModes(displayID),
      publicIndices: publicIndices, currentIndex: system.nativeCurrentModeIndex(displayID),
      kind: { system.refreshKind(displayID, index: $0) }
    )
  }

  func currentMode(_ displayID: UInt32) -> DisplayModeSummary? {
    modes(displayID).first(where: { $0.summary.isCurrent })?.summary
  }

  func configure(_ choice: DisplayModeChoice, displayID: UInt32) -> CGError {
    if let index = choice.nativeIndex {
      return system.configureNativeMode(index, displayID: displayID)
    }
    guard let mode = choice.systemMode else { return .illegalArgument }
    return CGDisplaySetDisplayMode(displayID, mode, nil)
  }

  private static func key(_ mode: CGDisplayMode) -> String {
    "\(mode.ioDisplayModeID)-\(mode.width)-\(mode.height)-\(mode.pixelWidth)-\(mode.pixelHeight)-\(Int((mode.refreshRate * 100).rounded()))"
  }
}

enum DisplayModeControlError: String, Error, LocalizedError {
  case disconnected = "The display has disconnected or changed. Refresh and try again."
  case unavailable = "The selected display mode is no longer available."
  case rejected = "macOS rejected this display mode."
  case unconfirmed = "macOS did not confirm the display mode change."

  var errorDescription: String? { rawValue }
}

@MainActor
final class DisplayModeControl {
  private let access: any DisplayModeAccessing
  private let verificationAttempts: Int
  private let verificationDelay: Duration

  init(
    access: any DisplayModeAccessing = NativeDisplayModeAccess(),
    verificationAttempts: Int = 20, verificationDelay: Duration = .milliseconds(100)
  ) {
    self.access = access
    self.verificationAttempts = max(1, verificationAttempts)
    self.verificationDelay = verificationDelay
  }

  func identity(_ displayID: UInt32) -> String? { access.identity(displayID) }
  func modes(_ displayID: UInt32) -> [DisplayModeSummary] { access.modes(displayID).map(\.summary) }
  func currentMode(_ displayID: UInt32) -> DisplayModeSummary? { access.currentMode(displayID) }

  func setMode(_ requested: DisplayModeSummary, displayID: UInt32, identity: String) async throws {
    guard access.identity(displayID) == identity else { throw DisplayModeControlError.disconnected }
    let current = access.currentMode(displayID)
    if current?.id == requested.id && current?.matches(requested) == true { return }
    guard let choice = DisplayModeCatalog.resolve(requested, in: access.modes(displayID)) else {
      throw DisplayModeControlError.unavailable
    }
    guard access.identity(displayID) == identity else { throw DisplayModeControlError.disconnected }
    guard access.configure(choice, displayID: displayID) == .success else {
      throw DisplayModeControlError.rejected
    }
    for attempt in 0..<verificationAttempts {
      guard access.identity(displayID) == identity else { throw DisplayModeControlError.disconnected }
      if let actual = access.currentMode(displayID), actual.matches(requested) {
        if actual.id == choice.summary.id { return }
        // Equal geometry can still describe distinct timing/color variants.
        // Accept a different ID only when the requested ID was really rebuilt.
        let fresh = access.modes(displayID)
        if !fresh.contains(where: { $0.summary.id == choice.summary.id }),
          DisplayModeCatalog.resolve(requested, in: fresh)?.summary.id == actual.id { return }
      }
      if attempt < verificationAttempts - 1 { try await Task.sleep(for: verificationDelay) }
    }
    throw DisplayModeControlError.unconfirmed
  }
}
