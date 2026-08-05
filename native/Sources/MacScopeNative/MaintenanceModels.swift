import Foundation

enum MaintenanceTool: String, CaseIterable, Identifiable, Sendable {
  case junk
  case applications
  case largeFiles
  case duplicates
  case downloads
  case memory

  var id: String { rawValue }
}

enum MaintenanceItemKind: String, Codable, Sendable {
  case cache
  case log
  case diagnostic
  case developer
  case application
  case startupItem
  case residue
  case largeFile
  case duplicate
  case download
}

struct FileIdentity: Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
  let size: UInt64
  let modified: TimeInterval
}

struct MaintenanceItem: Identifiable, Hashable, Sendable {
  let id: String
  let kind: MaintenanceItemKind
  let category: String
  let name: String
  let url: URL
  let size: UInt64
  let modified: Date
  let identity: FileIdentity
  let group: String
  let parentID: String?

  init(
    kind: MaintenanceItemKind,
    category: String,
    name: String? = nil,
    url: URL,
    size: UInt64,
    modified: Date,
    identity: FileIdentity,
    group: String = "",
    parentID: String? = nil
  ) {
    id = url.standardizedFileURL.path
    self.kind = kind
    self.category = category
    self.name = name ?? url.lastPathComponent
    self.url = url
    self.size = size
    self.modified = modified
    self.identity = identity
    self.group = group
    self.parentID = parentID
  }
}

struct ApplicationRecord: Identifiable, Hashable, Sendable {
  let application: MaintenanceItem
  let bundleIdentifier: String
  let version: String
  let startupConfigurations: [ApplicationStartupConfiguration]
  let loginItemsAccess: LoginItemsAccessState
  let residues: [MaintenanceItem]
  let otherCopies: [MaintenanceItem]
  let isRunning: Bool

  var id: String { application.id }
  var totalSize: UInt64 {
    application.size
      + residues.reduce(0) { $0 + $1.size }
      + otherCopies.reduce(0) { $0 + $1.size }
  }

  func replacing(isRunning: Bool) -> ApplicationRecord {
    ApplicationRecord(
      application: application,
      bundleIdentifier: bundleIdentifier,
      version: version,
      startupConfigurations: startupConfigurations,
      loginItemsAccess: loginItemsAccess,
      residues: residues,
      otherCopies: otherCopies,
      isRunning: isRunning
    )
  }
}

enum ScanIssueKind: String, Hashable, Sendable {
  case filesAndFolders
  case fullDiskAccess
  case folderAccess
  case unavailable
  case other
}

struct ScanIssue: Identifiable, Hashable, Sendable {
  let url: URL
  let kind: ScanIssueKind
  let detail: String

  var id: String {
    "\(kind.rawValue):\(url.standardizedFileURL.path)"
  }
}

struct ScanResult<Value: Sendable>: Sendable {
  let values: [Value]
  let issues: [ScanIssue]
  let scannedCount: Int
}

struct ScanProgress: Sendable {
  let scannedCount: Int
  let currentPath: String
}

enum MaintenanceFailureKind: String, Sendable {
  case notFound
  case changed
  case outsideScope
  case running
  case administratorRequired
  case fullDiskAccess
  case filesAndFolders
  case permission
  case operationFailed
}

struct MaintenanceFailure: Identifiable, Sendable {
  let item: MaintenanceItem
  let kind: MaintenanceFailureKind
  let detail: String

  var id: String { item.id }
}

struct CleanupResult: Sendable {
  let completed: [MaintenanceItem]
  let failures: [MaintenanceFailure]
  let reclaimedBytes: UInt64
  let authorizationCancelled: Bool
}

struct CleanupProgress: Sendable {
  let completed: Int
  let total: Int
  let item: MaintenanceItem
  let state: ActivityEntryState
  let detail: String
}

enum ActivityPhase: Sendable {
  case scanning
  case working
  case completed
  case cancelled
}

enum MaintenanceOperationKind: Sendable {
  case scan
  case cleanup
  case memory
}

enum ActivityEntryState: Sendable {
  case pending
  case working
  case completed
  case failed
}

struct ActivityEntry: Identifiable, Sendable {
  let id: String
  let name: String
  let path: String
  var state: ActivityEntryState
  var detail: String
}

struct MaintenanceActivity: Identifiable, Sendable {
  let id: UUID
  let tool: MaintenanceTool
  let operation: MaintenanceOperationKind
  let title: String
  var phase: ActivityPhase
  var completed: Int
  var total: Int
  var currentPath: String
  var entries: [ActivityEntry]
  var reclaimedBytes: UInt64
  var failures: [MaintenanceFailure]
  var scanIssues: [ScanIssue]

  var progress: Double? {
    total > 0 ? Double(completed) / Double(total) : nil
  }
}

enum MemoryReleaseResult: Sendable {
  case success
  case cancelled
  case failure(String)
}
