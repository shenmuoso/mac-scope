import Foundation

enum StartupItemKind: String, CaseIterable, Hashable, Sendable {
  case userAgent
  case globalAgent
  case daemon

  var requiresAdministrator: Bool {
    self != .userAgent
  }
}

enum StartupItemPermissionState: String, Hashable, Sendable {
  case allowed
  case disabled
  case requiresApproval
  case unavailable
}

enum StartupItemRuntimeState: Hashable, Sendable {
  case running(pid: Int32?)
  case waiting
  case unloaded
  case disabled
  case requiresApproval
  case unavailable

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }
}

enum StartupItemTriggerMode: String, Hashable, Sendable {
  case continuous
  case atLogin
  case atBoot
  case scheduled
  case onDemand
  case manual
}

enum StartupItemResidueState: String, Hashable, Sendable {
  case none
  case suspected
  case confirmed
}

enum StartupItemOwnerKind: String, Hashable, Sendable {
  case installedApplication
  case commandLineTool
  case unknown
}

struct StartupItem: Identifiable, Hashable, Sendable {
  let id: String
  let label: String
  let name: String
  let plistURL: URL
  let executableURL: URL?
  let requestedBundleIdentifier: String?
  let executableTeamIdentifier: String?
  let ownerName: String?
  let ownerBundleIdentifier: String?
  let ownerApplicationURL: URL?
  let kind: StartupItemKind
  let permissionState: StartupItemPermissionState
  let runtimeState: StartupItemRuntimeState
  let triggerMode: StartupItemTriggerMode
  let residueState: StartupItemResidueState
  let ownerKind: StartupItemOwnerKind
  let hasValidLabel: Bool
  let runAtLoad: Bool
  let keepAlive: Bool
  let parseIssue: String?

  var canChangePermission: Bool {
    hasValidLabel
      && permissionState != .requiresApproval
      && permissionState != .unavailable
  }

  var canRemove: Bool {
    residueState != .none
  }
}

struct SystemLoginItem: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let path: String?
  let isHidden: Bool
  let applicationURL: URL?
  let residueState: StartupItemResidueState

  var targetURL: URL? {
    path.map { URL(fileURLWithPath: $0).standardizedFileURL }
  }
}

enum LoginItemsAccessState: Hashable, Sendable {
  case available
  case denied
  case unavailable(String)
}

struct StartupItemApplication: Hashable, Sendable {
  let name: String
  let bundleIdentifier: String
  let url: URL
  let teamIdentifier: String?

  init(
    name: String,
    bundleIdentifier: String,
    url: URL,
    teamIdentifier: String? = nil
  ) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.url = url
    self.teamIdentifier = teamIdentifier
  }
}

struct StartupItemScanResult: Sendable {
  let loginItems: [SystemLoginItem]
  let backgroundItems: [StartupItem]
  let loginItemsAccess: LoginItemsAccessState
  let issues: [String]
}

enum StartupItemOperationResult: Sendable {
  case success
  case cancelled
  case failure(String)
}

enum StartupConfigurationSource: String, Hashable, Sendable {
  case loginItem
  case userLaunchAgent
  case globalLaunchAgent
  case systemDaemon
}

enum StartupAssociationConfidence: String, Hashable, Sendable {
  case confirmed
  case likely
}

struct ApplicationStartupConfiguration: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let source: StartupConfigurationSource
  let targetPath: String?
  let loginItem: SystemLoginItem?
  let launchItem: StartupItem?
  let cleanupItems: [MaintenanceItem]
  let confidence: StartupAssociationConfidence
  let evidence: String
  let isShared: Bool
  let isDefaultSelected: Bool

  var canRemove: Bool {
    !isShared && (loginItem != nil || !cleanupItems.isEmpty)
  }
}
