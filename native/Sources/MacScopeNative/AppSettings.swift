import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  var id: String { rawValue }
  var locale: Locale { Locale(identifier: rawValue) }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }
}

enum AppIconStyle: String, CaseIterable, Identifiable, Sendable {
  case minimal
  case detailed

  var id: String { rawValue }

  var resourceName: String {
    switch self {
    case .minimal: "MacScope"
    case .detailed: "MacScopeDetailed"
    }
  }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
  case celsius
  case fahrenheit

  var id: String { rawValue }
}

enum CacheCleanupMode: String, CaseIterable, Identifiable, Sendable {
  case trash
  case delete

  var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let language = "native.language"
    static let appearance = "native.appearance"
    static let appIconStyle = "native.appIconStyle"
    static let menuBarEnabled = "native.menuBarEnabled"
    static let menuBarDisplayMode = "native.menuBarDisplayMode"
    static let menuBarMetrics = "native.menuBarMetrics"
    static let menuBarModules = "native.menuBarModules"
    static let menuBarProcessSort = "native.menuBarProcessSort"
    static let menuBarProcessLimit = "native.menuBarProcessLimit"
    static let menuBarColorfulMode = "native.menuBarColorfulMode"
    static let sidebarTransparencyEnabled = "native.sidebarTransparencyEnabled"
    static let sidebarTransparency = "native.sidebarTransparency"
    static let refreshInterval = "native.refreshInterval"
    static let refreshIntervalDefault2Applied = "native.refreshIntervalDefault2Applied"
    static let temperatureUnit = "native.temperatureUnit"
    static let themeID = "native.themeID"
    static let cacheCleanupMode = "native.cacheCleanupMode"
    static let largeFileThresholdMB = "native.largeFileThresholdMB"
    static let duplicateMinimumMB = "native.duplicateMinimumMB"
    static let downloadCleanupAgeDays = "native.downloadCleanupAgeDays"
    static let scanFolderPaths = "native.scanFolderPaths"
    static let confirmsCleanup = "native.confirmsCleanup"
  }

  @Published var language: AppLanguage {
    didSet { defaults.set(language.rawValue, forKey: Key.language) }
  }

  @Published var appearance: AppAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
  }

  @Published var appIconStyle: AppIconStyle {
    didSet {
      defaults.set(appIconStyle.rawValue, forKey: Key.appIconStyle)
      AppIconController.apply(appIconStyle)
    }
  }

  @Published var menuBarEnabled: Bool {
    didSet { defaults.set(menuBarEnabled, forKey: Key.menuBarEnabled) }
  }

  @Published var menuBarDisplayMode: MenuBarDisplayMode {
    didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: Key.menuBarDisplayMode) }
  }

  @Published private(set) var menuBarMetrics: [MenuBarMetric] {
    didSet { defaults.set(menuBarMetrics.map(\.rawValue), forKey: Key.menuBarMetrics) }
  }

  @Published private(set) var menuBarModules: [MenuBarModule] {
    didSet { defaults.set(menuBarModules.map(\.rawValue), forKey: Key.menuBarModules) }
  }

  @Published var menuBarProcessSort: MenuBarProcessSort {
    didSet { defaults.set(menuBarProcessSort.rawValue, forKey: Key.menuBarProcessSort) }
  }

  @Published var menuBarProcessLimit: Int {
    didSet { defaults.set(menuBarProcessLimit, forKey: Key.menuBarProcessLimit) }
  }

  @Published var menuBarColorfulMode: Bool {
    didSet { defaults.set(menuBarColorfulMode, forKey: Key.menuBarColorfulMode) }
  }

  @Published var sidebarTransparencyEnabled: Bool {
    didSet { defaults.set(sidebarTransparencyEnabled, forKey: Key.sidebarTransparencyEnabled) }
  }

  @Published var sidebarTransparency: Double {
    didSet { defaults.set(sidebarTransparency, forKey: Key.sidebarTransparency) }
  }

  @Published var refreshInterval: Double {
    didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
  }

  @Published var temperatureUnit: TemperatureUnit {
    didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
  }

  @Published var themeID: String {
    didSet { defaults.set(themeID, forKey: Key.themeID) }
  }

  @Published var cacheCleanupMode: CacheCleanupMode {
    didSet { defaults.set(cacheCleanupMode.rawValue, forKey: Key.cacheCleanupMode) }
  }

  @Published var largeFileThresholdMB: Int {
    didSet { defaults.set(largeFileThresholdMB, forKey: Key.largeFileThresholdMB) }
  }

  @Published var duplicateMinimumMB: Int {
    didSet { defaults.set(duplicateMinimumMB, forKey: Key.duplicateMinimumMB) }
  }

  @Published var downloadCleanupAgeDays: Int {
    didSet { defaults.set(downloadCleanupAgeDays, forKey: Key.downloadCleanupAgeDays) }
  }

  @Published var scanFolderPaths: [String] {
    didSet { defaults.set(scanFolderPaths, forKey: Key.scanFolderPaths) }
  }

  @Published var confirmsCleanup: Bool {
    didSet { defaults.set(confirmsCleanup, forKey: Key.confirmsCleanup) }
  }

  var activeTheme: ThemePalette {
    ThemePalette.builtIns.first(where: { $0.id == themeID }) ?? ThemePalette.system
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
    appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    appIconStyle =
      AppIconStyle(rawValue: defaults.string(forKey: Key.appIconStyle) ?? "") ?? .minimal
    menuBarEnabled =
      defaults.object(forKey: Key.menuBarEnabled) == nil
      ? true : defaults.bool(forKey: Key.menuBarEnabled)
    menuBarDisplayMode =
      MenuBarDisplayMode(rawValue: defaults.string(forKey: Key.menuBarDisplayMode) ?? "")
      ?? .compact
    if defaults.object(forKey: Key.menuBarMetrics) == nil {
      menuBarMetrics = [.cpu, .memory]
    } else {
      menuBarMetrics = Array(
        Self.decode(MenuBarMetric.self, values: defaults.stringArray(forKey: Key.menuBarMetrics))
          .prefix(3)
      )
    }
    if defaults.object(forKey: Key.menuBarModules) == nil {
      menuBarModules = [.cpu, .memory, .disk, .network, .temperature, .processes]
    } else {
      menuBarModules = Self.decode(
        MenuBarModule.self,
        values: defaults.stringArray(forKey: Key.menuBarModules)
      )
    }
    menuBarProcessSort =
      MenuBarProcessSort(rawValue: defaults.string(forKey: Key.menuBarProcessSort) ?? "") ?? .cpu
    let savedMenuBarProcessLimit = defaults.integer(forKey: Key.menuBarProcessLimit)
    menuBarProcessLimit =
      [3, 5, 8, 10].contains(savedMenuBarProcessLimit)
      ? savedMenuBarProcessLimit : 5
    menuBarColorfulMode = defaults.bool(forKey: Key.menuBarColorfulMode)
    sidebarTransparencyEnabled =
      defaults.object(forKey: Key.sidebarTransparencyEnabled) == nil
      ? true : defaults.bool(forKey: Key.sidebarTransparencyEnabled)
    if defaults.object(forKey: Key.sidebarTransparency) == nil {
      sidebarTransparency = 0.7
    } else {
      sidebarTransparency = min(1, max(0, defaults.double(forKey: Key.sidebarTransparency)))
    }

    let savedInterval = defaults.double(forKey: Key.refreshInterval)
    if !defaults.bool(forKey: Key.refreshIntervalDefault2Applied), savedInterval == 1 {
      refreshInterval = 2
      defaults.set(2, forKey: Key.refreshInterval)
    } else {
      refreshInterval = [0.5, 1, 2, 5].contains(savedInterval) ? savedInterval : 2
    }
    defaults.set(true, forKey: Key.refreshIntervalDefault2Applied)
    temperatureUnit =
      TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius

    let savedThemeID = defaults.string(forKey: Key.themeID) ?? ThemePalette.system.id
    themeID =
      ThemePalette.builtIns.contains(where: { $0.id == savedThemeID })
      ? savedThemeID : ThemePalette.system.id
    defaults.removeObject(forKey: "native.customTheme")

    cacheCleanupMode =
      CacheCleanupMode(rawValue: defaults.string(forKey: Key.cacheCleanupMode) ?? "") ?? .trash
    let savedLargeThreshold = defaults.integer(forKey: Key.largeFileThresholdMB)
    largeFileThresholdMB =
      [100, 500, 1_024, 5_120].contains(savedLargeThreshold)
      ? savedLargeThreshold : 500
    let savedDuplicateMinimum = defaults.integer(forKey: Key.duplicateMinimumMB)
    duplicateMinimumMB =
      [1, 10, 100, 500].contains(savedDuplicateMinimum)
      ? savedDuplicateMinimum : 10
    let savedDownloadAge = defaults.integer(forKey: Key.downloadCleanupAgeDays)
    downloadCleanupAgeDays = [7, 30, 90, 180].contains(savedDownloadAge)
      ? savedDownloadAge : 30

    let savedFolders = defaults.stringArray(forKey: Key.scanFolderPaths) ?? []
    scanFolderPaths = savedFolders.isEmpty ? Self.defaultScanFolderPaths : savedFolders
    confirmsCleanup =
      defaults.object(forKey: Key.confirmsCleanup) == nil
      ? true : defaults.bool(forKey: Key.confirmsCleanup)
  }

  func resetAll() {
    language = .english
    appearance = .system
    appIconStyle = .minimal
    menuBarEnabled = true
    menuBarDisplayMode = .compact
    menuBarMetrics = [.cpu, .memory]
    menuBarModules = [.cpu, .memory, .disk, .network, .temperature, .processes]
    menuBarProcessSort = .cpu
    menuBarProcessLimit = 5
    menuBarColorfulMode = false
    sidebarTransparencyEnabled = true
    sidebarTransparency = 0.7
    refreshInterval = 2
    temperatureUnit = .celsius
    themeID = ThemePalette.system.id
    cacheCleanupMode = .trash
    largeFileThresholdMB = 500
    duplicateMinimumMB = 10
    downloadCleanupAgeDays = 30
    scanFolderPaths = Self.defaultScanFolderPaths
    confirmsCleanup = true
  }

  private static var defaultScanFolderPaths: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Downloads", "Desktop", "Documents", "Movies"].map {
      home.appendingPathComponent($0, isDirectory: true).path
    }
  }

  var orderedMenuBarMetrics: [MenuBarMetric] {
    menuBarMetrics + MenuBarMetric.allCases.filter { !menuBarMetrics.contains($0) }
  }

  var orderedMenuBarModules: [MenuBarModule] {
    menuBarModules + MenuBarModule.allCases.filter { !menuBarModules.contains($0) }
  }

  func setMenuBarMetric(_ metric: MenuBarMetric, isEnabled: Bool) {
    if isEnabled {
      guard !menuBarMetrics.contains(metric), menuBarMetrics.count < 3 else { return }
      menuBarMetrics.append(metric)
    } else {
      menuBarMetrics.removeAll { $0 == metric }
    }
  }

  func moveMenuBarMetric(_ metric: MenuBarMetric, offset: Int) {
    menuBarMetrics = Self.moving(metric, offset: offset, in: menuBarMetrics)
  }

  func setMenuBarModule(_ module: MenuBarModule, isEnabled: Bool) {
    if isEnabled {
      guard !menuBarModules.contains(module) else { return }
      menuBarModules.append(module)
    } else {
      menuBarModules.removeAll { $0 == module }
    }
  }

  func moveMenuBarModule(_ module: MenuBarModule, offset: Int) {
    menuBarModules = Self.moving(module, offset: offset, in: menuBarModules)
  }

  private static func decode<Value>(
    _ type: Value.Type,
    values: [String]?
  ) -> [Value] where Value: RawRepresentable & Hashable, Value.RawValue == String {
    var seen: Set<Value> = []
    var result: [Value] = []
    for rawValue in values ?? [] {
      guard let value = Value(rawValue: rawValue), seen.insert(value).inserted else { continue }
      result.append(value)
    }
    return result
  }

  private static func moving<Value: Equatable>(
    _ value: Value,
    offset: Int,
    in values: [Value]
  ) -> [Value] {
    guard let source = values.firstIndex(of: value) else { return values }
    let destination = min(values.count - 1, max(0, source + offset))
    guard source != destination else { return values }
    var result = values
    result.remove(at: source)
    result.insert(value, at: destination)
    return result
  }
}
