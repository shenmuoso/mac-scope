import AppKit
import Combine
import Foundation
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
  case overview
  case performancePower
  case processes
  case systemInfo
  case battery
  case ports
  case downloads
  case junk
  case applications
  case largeFiles
  case duplicates
  case memory

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .overview: "Overview"
    case .performancePower: "Performance & Power"
    case .processes: "Process Management"
    case .systemInfo: "System Information"
    case .battery: "Battery Health"
    case .ports: "Ports"
    case .downloads: "Downloads Cleanup"
    case .junk: "Junk Cleanup"
    case .applications: "Applications"
    case .largeFiles: "Large Files"
    case .duplicates: "Duplicates"
    case .memory: "Memory"
    }
  }

  var pageDescription: LocalizedStringKey {
    switch self {
    case .overview:
      "Live CPU, memory, disk, and network activity."
    case .performancePower:
      "Real-time CPU, power, temperature, and cooling activity."
    case .processes:
      "Inspect, group, and manage running processes and software."
    case .systemInfo:
      "Hardware, storage, displays, and connected devices on this Mac."
    case .battery:
      "Charge, capacity, cycle count, temperature, and electrical condition."
    case .ports:
      "Listening ports and the processes and software using them."
    case .downloads:
      "Installers, archives, and older files in your Downloads folder."
    case .junk:
      "Caches, logs, diagnostics, and developer data."
    case .applications:
      "Installed applications and their related data."
    case .largeFiles:
      "Files above the size threshold in your selected folders."
    case .duplicates:
      "Byte-for-byte matches in your selected folders."
    case .memory:
      "Current memory pressure and inactive file cache."
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .performancePower: "bolt.circle"
    case .processes: "list.bullet.rectangle"
    case .systemInfo: "desktopcomputer"
    case .battery: "battery.100percent"
    case .ports: "network"
    case .downloads: "arrow.down.circle"
    case .junk: "trash"
    case .applications: "app.dashed"
    case .largeFiles: "externaldrive.badge.exclamationmark"
    case .duplicates: "doc.on.doc"
    case .memory: "memorychip"
    }
  }

  var iconColor: Color {
    switch self {
    case .overview:
      Color(nsColor: .black)
    case .performancePower:
      Color(nsColor: .systemOrange)
    case .processes:
      Color(nsColor: .systemGray)
    case .systemInfo:
      Color(nsColor: .systemGray)
    case .battery, .memory:
      Color(nsColor: .systemGreen)
    case .ports:
      Color(nsColor: .systemBlue)
    case .downloads, .junk, .largeFiles, .duplicates:
      Color(nsColor: .systemRed)
    case .applications:
      Color(nsColor: .systemPurple)
    }
  }
}

struct ProcessInspectionRequest: Equatable, Identifiable, Sendable {
  let id = UUID()
  let pid: Int32
}

@MainActor
final class AppNavigation: ObservableObject {
  private static let destinationKey = "native.sidebarDestination"

  @Published var destination: AppDestination {
    didSet { defaults.set(destination.rawValue, forKey: Self.destinationKey) }
  }
  @Published private(set) var processInspectionRequest: ProcessInspectionRequest?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    destination =
      AppDestination(rawValue: defaults.string(forKey: Self.destinationKey) ?? "") ?? .overview
  }

  func inspectProcess(_ pid: Int32) {
    destination = .processes
    processInspectionRequest = ProcessInspectionRequest(pid: pid)
  }

  func completeProcessInspection(_ request: ProcessInspectionRequest) {
    guard processInspectionRequest?.id == request.id else { return }
    processInspectionRequest = nil
  }
}

@MainActor
enum AppWindowActions {
  static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MacScope.MainWindow")

  static func activate() {
    NSApp.activate(ignoringOtherApps: true)
  }

  static func openSettings() {
    showSettings()
  }

  static func openSettings(tab: String) {
    UserDefaults.standard.set(tab, forKey: "native.settingsTab")
    showSettings()
  }

  private static func showSettings() {
    activate()
    let didOpen = NSApp.sendAction(
      Selector(("showSettingsWindow:")),
      to: nil,
      from: nil
    )
    if !didOpen {
      NSApp.sendAction(
        Selector(("showPreferencesWindow:")),
        to: nil,
        from: nil
      )
    }
  }

  static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier == mainWindowIdentifier }
  }
}
