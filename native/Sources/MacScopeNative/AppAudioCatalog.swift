import CoreAudio
import Foundation

struct AudioProcessSnapshot: Equatable, Sendable, Identifiable {
  var objectID: AudioObjectID
  var pid: pid_t
  var bundleID: String?
  var executablePath: String? = nil

  var id: pid_t { pid }
}

struct AppAudioLevel: Codable, Equatable, Sendable {
  var volume: Double
  var isMuted: Bool
  var name: String
  var bundlePath: String?
  /// Empty follows the system default output device.
  var outputDeviceUIDs: [String]
  var routesToMultipleDevices: Bool
  /// 1, 2, 3, or 4. The slider stays at 100% and this multiplies it.
  var boost: Double
  var eqGains: [Double]

  init(
    volume: Double,
    isMuted: Bool,
    name: String,
    bundlePath: String?,
    outputDeviceUIDs: [String] = [],
    routesToMultipleDevices: Bool = false,
    boost: Double = 1,
    eqGains: [Double] = AppAudioEQ.flat
  ) {
    self.volume = volume
    self.isMuted = isMuted
    self.name = name
    self.bundlePath = bundlePath
    self.outputDeviceUIDs = outputDeviceUIDs
    self.routesToMultipleDevices = routesToMultipleDevices
    self.boost = boost
    self.eqGains = eqGains
  }

  static let full = AppAudioLevel(volume: 1, isMuted: false, name: "", bundlePath: nil)

  var clamped: AppAudioLevel {
    var copy = self
    copy.volume = min(1, max(0, volume))
    copy.outputDeviceUIDs = outputDeviceUIDs.filter { !$0.isEmpty }
    let choices = [1.0, 2.0, 3.0, 4.0]
    copy.boost = choices.min { abs($0 - boost) < abs($1 - boost) } ?? 1
    copy.eqGains = AppAudioEQ.normalized(eqGains)
    return copy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    volume = try container.decode(Double.self, forKey: .volume)
    isMuted = try container.decode(Bool.self, forKey: .isMuted)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
    let storedDevices = try container.decodeIfPresent([String].self, forKey: .outputDeviceUIDs) ?? []
    if storedDevices.isEmpty,
      let legacy = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID),
      !legacy.isEmpty
    {
      outputDeviceUIDs = [legacy]
    } else {
      outputDeviceUIDs = storedDevices
    }
    routesToMultipleDevices = try container.decodeIfPresent(Bool.self, forKey: .routesToMultipleDevices) ?? false
    boost = try container.decodeIfPresent(Double.self, forKey: .boost) ?? 1
    eqGains = try container.decodeIfPresent([Double].self, forKey: .eqGains) ?? AppAudioEQ.flat
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(volume, forKey: .volume)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(bundlePath, forKey: .bundlePath)
    try container.encode(outputDeviceUIDs, forKey: .outputDeviceUIDs)
    try container.encode(routesToMultipleDevices, forKey: .routesToMultipleDevices)
    try container.encode(boost, forKey: .boost)
    try container.encode(eqGains, forKey: .eqGains)
  }

  private enum CodingKeys: String, CodingKey {
    case volume
    case isMuted
    case name
    case bundlePath
    case outputDeviceUID
    case outputDeviceUIDs
    case routesToMultipleDevices
    case boost
    case eqGains
  }
}

struct AppAudioGroup: Equatable, Sendable {
  var key: String
  var processes: [AudioProcessSnapshot]
  var level: AppAudioLevel

  var isPlaying: Bool { !processes.isEmpty }
}

enum AppAudioRoute {
  static var isPerAppSupported: Bool {
    if #available(macOS 14.2, *) {
      return true
    }
    return false
  }

  static func needsTap(_ level: AppAudioLevel, systemDeviceUID: String? = nil) -> Bool {
    let level = level.clamped
    if level.isMuted || level.volume < 0.999 || level.boost > 1.001 || !AppAudioEQ.isFlat(level.eqGains) {
      return true
    }
    if level.outputDeviceUIDs.count > 1 { return true }
    guard let selected = level.outputDeviceUIDs.first else { return false }
    return selected != systemDeviceUID
  }

  static func gain(for level: AppAudioLevel) -> Float {
    let level = level.clamped
    guard !level.isMuted else { return 0 }
    return Float(level.volume * level.boost)
  }
}

enum AppAudioCatalog {
  static func key(bundleID: String?, pid: pid_t) -> String {
    if let bundleID, !bundleID.isEmpty {
      return bundleID
    }
    return "pid:\(pid)"
  }

  static func groups(
    processes: [AudioProcessSnapshot],
    levels: [String: AppAudioLevel],
    excludedPIDs: Set<pid_t>,
    excludedBundleIDs: Set<String>
  ) -> [AppAudioGroup] {
    var grouped: [String: [AudioProcessSnapshot]] = [:]
    for process in processes where process.pid > 0 && !excludedPIDs.contains(process.pid) {
      if let bundleID = process.bundleID, excludedBundleIDs.contains(bundleID) {
        continue
      }
      let key = AppAudioOwningApp.groupKey(for: process)
      if excludedBundleIDs.contains(key) { continue }
      grouped[key, default: []].append(process)
    }

    var keys = Set(grouped.keys)
    for key in levels.keys where AppAudioRoute.needsTap(levels[key] ?? .full) {
      keys.insert(key)
    }

    return keys.map { key in
      let processes = (grouped[key] ?? []).sorted { $0.pid < $1.pid }
      let stored = levels[key] ?? .full
      return AppAudioGroup(key: key, processes: processes, level: stored.clamped)
    }
  }
}

enum AppAudioOwningApp {
  static func applicationPath(executablePath: String) -> String? {
    var url = URL(fileURLWithPath: executablePath)
    var outermost: String?
    while url.path != "/" {
      if url.pathExtension == "app" {
        outermost = url.path
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    return outermost
  }

  static func bundleIdentifier(appPath: String) -> String? {
    let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    guard let identifier = NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String,
      !identifier.isEmpty
    else { return nil }
    return identifier
  }

  static func groupKey(for process: AudioProcessSnapshot) -> String {
    if let appPath = resolvedApplicationPath(
      executablePath: process.executablePath,
      bundleID: process.bundleID
    ) {
      if let identifier = bundleIdentifier(appPath: appPath) {
        return identifier
      }
      return "app:\(appPath)"
    }
    return AppAudioCatalog.key(bundleID: process.bundleID, pid: process.pid)
  }

  /// System audio servers that play on behalf of a user-facing app.
  static func resolvedApplicationPath(executablePath: String?, bundleID: String?) -> String? {
    if let executablePath, let nested = applicationPath(executablePath: executablePath) {
      return nested
    }
    let names = [bundleID, executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }]
      .compactMap { $0 }
    for name in names {
      guard let appPath = knownApplications[name], FileManager.default.fileExists(atPath: appPath) else {
        continue
      }
      return appPath
    }
    return nil
  }

  private static let knownApplications = [
    "avconferenced": "/System/Applications/FaceTime.app",
    "com.apple.avconferenced": "/System/Applications/FaceTime.app",
  ]
}

enum AppAudioLevelStore {
  static let defaultsKey = "native.appAudioLevels"

  static func load(from defaults: UserDefaults) -> [String: AppAudioLevel] {
    guard let data = defaults.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([String: AppAudioLevel].self, from: data)
    else {
      return [:]
    }
    return decoded.mapValues(\.clamped).filter { AppAudioRoute.needsTap($0.value) }
  }

  static func save(_ levels: [String: AppAudioLevel], to defaults: UserDefaults) {
    let stored = levels.filter { AppAudioRoute.needsTap($0.value) }
    guard let data = try? JSONEncoder().encode(stored) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}
