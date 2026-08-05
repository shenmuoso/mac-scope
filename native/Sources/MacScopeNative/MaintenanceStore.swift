import AppKit
import Combine
import Foundation

@MainActor
final class MaintenanceStore: ObservableObject {
  @Published private(set) var junkItems: [MaintenanceItem] = []
  @Published private(set) var applications: [ApplicationRecord] = []
  @Published private(set) var largeFileItems: [MaintenanceItem] = []
  @Published private(set) var duplicateItems: [MaintenanceItem] = []
  @Published private(set) var downloadItems: [MaintenanceItem] = []
  @Published private(set) var issuesByTool: [MaintenanceTool: [ScanIssue]] = [:]
  @Published private(set) var scannedTools: Set<MaintenanceTool> = []
  @Published var activity: MaintenanceActivity?
  @Published private(set) var memoryMessage = ""

  private let service = MaintenanceService()
  private var operationTask: Task<Void, Never>?
  private var language = AppLanguage.english
  private var lastScanProgressUpdate = -TimeInterval.infinity

  var isBusy: Bool {
    guard let phase = activity?.phase else { return false }
    return phase == .scanning || phase == .working
  }

  var needsFullDiskAccess: Bool {
    activity?.failures.contains(where: { $0.kind == .fullDiskAccess }) == true
      || activity?.scanIssues.contains(where: { $0.kind == .fullDiskAccess }) == true
  }

  var needsFilesAndFoldersAccess: Bool {
    activity?.failures.contains(where: { $0.kind == .filesAndFolders }) == true
      || activity?.scanIssues.contains(where: { $0.kind == .filesAndFolders }) == true
  }

  var needsScanFolderAccess: Bool {
    activity?.scanIssues.contains(where: { $0.kind == .folderAccess }) == true
  }

  func updateLanguage(_ language: AppLanguage) {
    self.language = language
  }

  func scanJunk() {
    beginScan(tool: .junk, title: l("Scanning Junk")) { [service] reporter in
      try await service.scanJunk(progress: reporter)
    } apply: { result in
      self.junkItems = result.values
    }
  }

  func scanApplications() {
    NSApp.activate(ignoringOtherApps: true)
    beginScan(tool: .applications, title: l("Scanning Applications")) { [service] reporter in
      try await service.scanApplications(progress: reporter)
    } apply: { result in
      self.applications = result.values
    }
  }

  func scanLargeFiles(settings: AppSettings) {
    let roots = settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let threshold = settings.largeFileThresholdMB
    beginScan(tool: .largeFiles, title: l("Scanning Large Files")) { [service] reporter in
      try await service.scanLargeFiles(
        roots: roots,
        thresholdMB: threshold,
        progress: reporter
      )
    } apply: { result in
      self.largeFileItems = result.values
    }
  }

  func scanDuplicates(settings: AppSettings) {
    let roots = settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let minimum = settings.duplicateMinimumMB
    beginScan(tool: .duplicates, title: l("Scanning Duplicates")) { [service] reporter in
      try await service.scanDuplicates(
        roots: roots,
        minimumMB: minimum,
        progress: reporter
      )
    } apply: { result in
      self.duplicateItems = result.values
    }
  }

  func scanDownloads(settings: AppSettings) {
    let ageDays = settings.downloadCleanupAgeDays
    beginScan(tool: .downloads, title: l("Scanning Downloads")) { [service] reporter in
      try await service.scanDownloads(olderThanDays: ageDays, progress: reporter)
    } apply: { result in
      self.downloadItems = result.values
    }
  }

  func retryScan(tool: MaintenanceTool, settings: AppSettings) {
    switch tool {
    case .junk:
      scanJunk()
    case .applications:
      scanApplications()
    case .largeFiles:
      scanLargeFiles(settings: settings)
    case .duplicates:
      scanDuplicates(settings: settings)
    case .downloads:
      scanDownloads(settings: settings)
    case .memory:
      break
    }
  }

  func cleanJunk(_ items: [MaintenanceItem], settings: AppSettings) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    beginCleanup(
      tool: .junk,
      title: l("Cleaning Junk"),
      items: items,
      cacheMode: settings.cacheCleanupMode,
      roots: [root]
    )
  }

  func removeLargeFiles(_ items: [MaintenanceItem], settings: AppSettings) {
    beginCleanup(
      tool: .largeFiles,
      title: l("Removing Large Files"),
      items: items,
      cacheMode: .trash,
      roots: settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
  }

  func removeDuplicates(_ items: [MaintenanceItem], settings: AppSettings) {
    beginCleanup(
      tool: .duplicates,
      title: l("Removing Duplicates"),
      items: items,
      cacheMode: .trash,
      roots: settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
  }

  func removeDownloads(_ items: [MaintenanceItem]) {
    let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Downloads",
      isDirectory: true
    )
    beginCleanup(
      tool: .downloads,
      title: l("Cleaning Downloads"),
      items: items,
      cacheMode: .trash,
      roots: [downloads]
    )
  }

  func uninstall(
    _ record: ApplicationRecord,
    selectedIDs: Set<MaintenanceItem.ID>,
    selectedStartupConfigurationIDs: Set<ApplicationStartupConfiguration.ID>
  ) {
    guard !record.isRunning else { return }
    let selectedConfigurations = record.startupConfigurations.filter {
      selectedStartupConfigurationIDs.contains($0.id) && $0.canRemove && !$0.isShared
    }
    let candidates = [record.application] + record.otherCopies + record.residues
    let selectedFiles = candidates.filter { selectedIDs.contains($0.id) }
    let launchConfigurationFiles = selectedConfigurations.flatMap(\.cleanupItems)
    let items = selectedFiles + launchConfigurationFiles
    let loginConfigurations = selectedConfigurations.filter { $0.loginItem != nil }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let requiresAdministrator = items.contains { item in
      let path = item.url.standardizedFileURL.path
      return (item.kind == .application && path.hasPrefix("/Applications/"))
        || (item.kind == .startupItem
          && (path.hasPrefix("/Library/LaunchAgents/")
            || path.hasPrefix("/Library/LaunchDaemons/")
            || path.hasPrefix("/Library/PrivilegedHelperTools/")))
    }
    if requiresAdministrator {
      NSApp.activate(ignoringOtherApps: true)
    }
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
      home.appendingPathComponent("Library", isDirectory: true),
      URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
      URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
      URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true),
    ]
    runApplicationUninstall(
      title: l("Uninstalling %@", record.application.name),
      items: items,
      startupConfigurations: selectedConfigurations,
      loginConfigurations: loginConfigurations,
      roots: roots,
      authorize: requiresAdministrator
    )
  }

  func openAutomationSettings() {
    SystemPermission.openAutomationSettings()
  }

  func releaseMemory() {
    cancelCurrentOperation()
    NSApp.activate(ignoringOtherApps: true)
    memoryMessage = ""
    activity = MaintenanceActivity(
      id: UUID(),
      tool: .memory,
      operation: .memory,
      title: l("Releasing File Cache"),
      phase: .working,
      completed: 0,
      total: 1,
      currentPath: l("Requesting macOS to release inactive file cache"),
      entries: [],
      reclaimedBytes: 0,
      failures: [],
      scanIssues: []
    )
    operationTask = Task { [weak self, service] in
      guard let self else { return }
      let result = await service.releaseMemory()
      guard !Task.isCancelled else { return }
      switch result {
      case .success:
        memoryMessage = l("macOS released eligible inactive file cache.")
        activity?.phase = .completed
        activity?.completed = 1
        activity?.currentPath = memoryMessage
      case .cancelled:
        memoryMessage = l("Cancelled")
        activity?.phase = .cancelled
        activity?.completed = 0
        activity?.currentPath = memoryMessage
      case .failure(let message):
        memoryMessage = message
        activity?.phase = .completed
        activity?.completed = 1
        activity?.currentPath = message
      }
    }
  }

  func quitApplication(_ record: ApplicationRecord) {
    let paths = Set(
      ([record.application] + record.otherCopies).map { $0.url.standardizedFileURL.path }
    )
    let matching = NSWorkspace.shared.runningApplications.filter { application in
      guard let path = application.bundleURL?.standardizedFileURL.path else { return false }
      return paths.contains(path)
    }
    matching.forEach { _ = $0.terminate() }

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard let self else { return }
      let runningPaths = Set(
        NSWorkspace.shared.runningApplications.compactMap {
          $0.bundleURL?.standardizedFileURL.path
        }
      )
      applications = applications.map { application in
        guard application.id == record.id else { return application }
        let allPaths = ([application.application] + application.otherCopies).map {
          $0.url.standardizedFileURL.path
        }
        return application.replacing(isRunning: allPaths.contains(where: runningPaths.contains))
      }
    }
  }

  func cancelCurrentOperation() {
    operationTask?.cancel()
    operationTask = nil
    if isBusy {
      activity?.phase = .cancelled
      activity?.currentPath = l("Cancelled")
    }
  }

  func dismissActivity() {
    guard !isBusy else { return }
    activity = nil
  }

  private func beginScan<Value: Sendable>(
    tool: MaintenanceTool,
    title: String,
    operation:
      @escaping @Sendable (MaintenanceService.ScanReporter) async throws -> ScanResult<Value>,
    apply: @escaping @MainActor (ScanResult<Value>) -> Void
  ) {
    cancelCurrentOperation()
    lastScanProgressUpdate = -TimeInterval.infinity
    activity = MaintenanceActivity(
      id: UUID(),
      tool: tool,
      operation: .scan,
      title: title,
      phase: .scanning,
      completed: 0,
      total: 0,
      currentPath: l("Preparing scan"),
      entries: [],
      reclaimedBytes: 0,
      failures: [],
      scanIssues: []
    )
    operationTask = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let result = try await operation { [weak self] progress in
          await self?.updateScanProgress(progress)
        }
        guard !Task.isCancelled else { return }
        apply(result)
        scannedTools.insert(tool)
        issuesByTool[tool] = result.issues
        if result.issues.isEmpty {
          activity = nil
          return
        }
        activity?.phase = .completed
        activity?.completed = result.scannedCount
        activity?.currentPath = l("Found %lld items", Int64(result.values.count))
        activity?.scanIssues = result.issues
        activity?.entries = result.issues.prefix(50).map { issue in
          ActivityEntry(
            id: issue.id,
            name: scanIssueTitle(issue.kind),
            path: issue.url.path,
            state: .failed,
            detail: issue.detail
          )
        }
      } catch is CancellationError {
        activity?.phase = .cancelled
        activity?.currentPath = l("Cancelled")
      } catch {
        issuesByTool[tool] = []
        activity?.phase = .completed
        activity?.currentPath = error.localizedDescription
        activity?.entries = [
          ActivityEntry(
            id: "scan-error",
            name: l("Scan Failed"),
            path: "",
            state: .failed,
            detail: error.localizedDescription
          )
        ]
      }
    }
  }

  private func updateScanProgress(_ progress: ScanProgress) {
    guard activity?.phase == .scanning else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastScanProgressUpdate >= 0.2 else { return }
    lastScanProgressUpdate = now
    guard var nextActivity = activity else { return }
    nextActivity.completed = progress.scannedCount
    nextActivity.currentPath = progress.currentPath
    activity = nextActivity
  }

  private func beginCleanup(
    tool: MaintenanceTool,
    title: String,
    items: [MaintenanceItem],
    cacheMode: CacheCleanupMode,
    roots: [URL],
    authorize: Bool = false
  ) {
    guard !items.isEmpty else { return }
    let request = CleanupRequest(
      tool: tool,
      title: title,
      items: items,
      cacheMode: cacheMode,
      roots: roots
    )
    runCleanup(request, authorize: authorize)
  }

  private func runCleanup(_ request: CleanupRequest, authorize: Bool) {
    cancelCurrentOperation()
    activity = MaintenanceActivity(
      id: UUID(),
      tool: request.tool,
      operation: .cleanup,
      title: authorize ? l("Authorizing Cleanup") : request.title,
      phase: .working,
      completed: 0,
      total: request.items.count,
      currentPath: l("Preparing"),
      entries: request.items.map {
        ActivityEntry(
          id: $0.id,
          name: $0.name,
          path: $0.url.path,
          state: .pending,
          detail: ""
        )
      },
      reclaimedBytes: 0,
      failures: [],
      scanIssues: []
    )
    operationTask = Task { [weak self, service] in
      guard let self else { return }
      let result = await service.cleanup(
        items: request.items,
        cacheMode: request.cacheMode,
        allowedRoots: request.roots,
        authorize: authorize
      ) { [weak self] progress in
        await self?.updateCleanupProgress(progress)
      }
      guard !Task.isCancelled else { return }
      activity?.phase = result.authorizationCancelled ? .cancelled : .completed
      activity?.completed = result.authorizationCancelled
        ? result.completed.count : request.items.count
      if result.authorizationCancelled {
        activity?.currentPath = l("Cancelled")
      } else {
        activity?.currentPath =
          result.failures.isEmpty
          ? l("Completed %lld items", Int64(result.completed.count))
          : l("Completed with %lld issues", Int64(result.failures.count))
      }
      activity?.reclaimedBytes = result.reclaimedBytes
      activity?.failures = result.failures
      removeCompleted(result.completed, from: request.tool)
    }
  }

  private func runApplicationUninstall(
    title: String,
    items: [MaintenanceItem],
    startupConfigurations: [ApplicationStartupConfiguration],
    loginConfigurations: [ApplicationStartupConfiguration],
    roots: [URL],
    authorize: Bool
  ) {
    cancelCurrentOperation()
    let loginEntries = loginConfigurations.map { configuration in
      ActivityEntry(
        id: configuration.id,
        name: configuration.name,
        path: configuration.targetPath ?? l("Open at Login"),
        state: .pending,
        detail: ""
      )
    }
    activity = MaintenanceActivity(
      id: UUID(),
      tool: .applications,
      operation: .cleanup,
      title: title,
      phase: .working,
      completed: 0,
      total: loginEntries.count + items.count,
      currentPath: l("Preparing"),
      entries: loginEntries + items.map {
        ActivityEntry(
          id: $0.id,
          name: $0.name,
          path: $0.url.path,
          state: .pending,
          detail: ""
        )
      },
      reclaimedBytes: 0,
      failures: [],
      scanIssues: []
    )

    let startupService = StartupItemService()
    operationTask = Task { [weak self, service] in
      guard let self else { return }
      let preflightFailures = await service.preflightCleanup(
        items: items,
        allowedRoots: roots
      )
      guard !Task.isCancelled else { return }
      if !preflightFailures.isEmpty {
        for failure in preflightFailures {
          markActivityEntry(
            id: failure.item.id,
            state: .failed,
            detail: failure.detail
          )
        }
        activity?.phase = .completed
        activity?.completed = preflightFailures.count
        activity?.currentPath = l("Uninstall was not started because selected items changed.")
        activity?.failures = preflightFailures
        return
      }

      var completedStartupConfigurationIDs = Set<ApplicationStartupConfiguration.ID>()
      var startupFailureCount = 0
      for configuration in loginConfigurations {
        guard !Task.isCancelled, let loginItem = configuration.loginItem else { continue }
        markActivityEntry(id: configuration.id, state: .working, detail: "")
        let result = await startupService.removeLoginItem(loginItem)
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
          completedStartupConfigurationIDs.insert(configuration.id)
          markActivityEntry(
            id: configuration.id,
            state: .completed,
            detail: l("Removed from Open at Login")
          )
        case .cancelled:
          startupFailureCount += 1
          markActivityEntry(
            id: configuration.id,
            state: .failed,
            detail: l("Cancelled")
          )
        case .failure(let message):
          startupFailureCount += 1
          markActivityEntry(id: configuration.id, state: .failed, detail: message)
        }
        activity?.completed = completedStartupConfigurationIDs.count + startupFailureCount
      }

      let offset = loginConfigurations.count
      let result = await service.cleanup(
        items: items,
        cacheMode: .trash,
        allowedRoots: roots,
        authorize: authorize
      ) { [weak self] progress in
        await self?.updateApplicationCleanupProgress(progress, offset: offset)
      }
      guard !Task.isCancelled else { return }

      let completedFileIDs = Set(result.completed.map(\.id))
      for configuration in startupConfigurations {
        let configurationFileIDs = Set(configuration.cleanupItems.map(\.id))
        if !configurationFileIDs.isEmpty,
          configurationFileIDs.isSubset(of: completedFileIDs)
        {
          completedStartupConfigurationIDs.insert(configuration.id)
        }
      }

      if !result.authorizationCancelled {
        let verification = await startupService.scan()
        if case .available = verification.loginItemsAccess {
          for configuration in loginConfigurations
          where completedStartupConfigurationIDs.contains(configuration.id) {
            guard let original = configuration.loginItem else { continue }
            let remains = verification.loginItems.contains {
              $0.name == original.name && $0.path == original.path
            }
            if remains {
              completedStartupConfigurationIDs.remove(configuration.id)
              startupFailureCount += 1
              markActivityEntry(
                id: configuration.id,
                state: .failed,
                detail: l("Still present after uninstall")
              )
            }
          }
        }
        for configuration in startupConfigurations
        where configuration.loginItem == nil
          && completedStartupConfigurationIDs.contains(configuration.id)
        {
          guard let original = configuration.launchItem else { continue }
          let remains = verification.backgroundItems.contains {
            $0.plistURL.standardizedFileURL.path
              == original.plistURL.standardizedFileURL.path
          }
          if remains {
            completedStartupConfigurationIDs.remove(configuration.id)
            startupFailureCount += 1
            markActivityEntry(
              id: configuration.cleanupItems.first?.id ?? configuration.id,
              state: .failed,
              detail: l("Still present after uninstall")
            )
          }
        }
      }

      activity?.phase = result.authorizationCancelled ? .cancelled : .completed
      activity?.completed = result.authorizationCancelled
        ? offset + result.completed.count
        : offset + items.count
      let issueCount = result.failures.count + startupFailureCount
      if result.authorizationCancelled {
        activity?.currentPath = l("Cancelled")
      } else if issueCount == 0 {
        let completedLoginCount = loginConfigurations.filter {
          completedStartupConfigurationIDs.contains($0.id)
        }.count
        activity?.currentPath = l(
          "Completed %lld items",
          Int64(result.completed.count + completedLoginCount)
        )
      } else {
        activity?.currentPath = l("Completed with %lld issues", Int64(issueCount))
      }
      activity?.reclaimedBytes = result.reclaimedBytes
      activity?.failures = result.failures
      removeCompleted(result.completed, from: .applications)
      removeStartupConfigurations(completedStartupConfigurationIDs)
    }
  }

  private func updateApplicationCleanupProgress(
    _ progress: CleanupProgress,
    offset: Int
  ) {
    guard activity?.phase == .working else { return }
    activity?.completed = offset + progress.completed
    activity?.total = offset + progress.total
    activity?.currentPath = progress.item.url.path
    markActivityEntry(
      id: progress.item.id,
      state: progress.state,
      detail: progress.detail
    )
  }

  private func markActivityEntry(
    id: String,
    state: ActivityEntryState,
    detail: String
  ) {
    guard let index = activity?.entries.firstIndex(where: { $0.id == id }) else { return }
    activity?.entries[index].state = state
    activity?.entries[index].detail = detail
  }

  private func updateCleanupProgress(_ progress: CleanupProgress) {
    guard activity?.phase == .working else { return }
    activity?.completed = progress.completed
    activity?.total = progress.total
    activity?.currentPath = progress.item.url.path
    if let index = activity?.entries.firstIndex(where: { $0.id == progress.item.id }) {
      activity?.entries[index].state = progress.state
      activity?.entries[index].detail = progress.detail
    }
  }

  private func scanIssueTitle(_ kind: ScanIssueKind) -> String {
    switch kind {
    case .filesAndFolders:
      l("Files & Folders Access Required")
    case .fullDiskAccess:
      l("Full Disk Access Required")
    case .folderAccess:
      l("Scan Folder Access Required")
    case .unavailable:
      l("Folder Unavailable")
    case .other:
      l("Scan Warning")
    }
  }

  private func removeCompleted(_ items: [MaintenanceItem], from tool: MaintenanceTool) {
    let ids = Set(items.map(\.id))
    switch tool {
    case .junk:
      junkItems.removeAll { ids.contains($0.id) }
    case .largeFiles:
      largeFileItems.removeAll { ids.contains($0.id) }
    case .duplicates:
      duplicateItems.removeAll { ids.contains($0.id) }
      let remainingGroups = Dictionary(grouping: duplicateItems, by: \.group)
        .filter { $0.value.count > 1 }
        .map(\.key)
      duplicateItems.removeAll { !remainingGroups.contains($0.group) }
    case .downloads:
      downloadItems.removeAll { ids.contains($0.id) }
    case .applications:
      applications = applications.compactMap { record in
        if ids.contains(record.application.id) {
          let remainingCopies = record.otherCopies.filter { !ids.contains($0.id) }
          guard let promoted = remainingCopies.first else { return nil }
          return ApplicationRecord(
            application: promoted,
            bundleIdentifier: record.bundleIdentifier,
            version: record.version,
            startupConfigurations: record.startupConfigurations,
            loginItemsAccess: record.loginItemsAccess,
            residues: record.residues.filter { !ids.contains($0.id) },
            otherCopies: Array(remainingCopies.dropFirst()),
            isRunning: record.isRunning
          )
        }
        return ApplicationRecord(
          application: record.application,
          bundleIdentifier: record.bundleIdentifier,
          version: record.version,
          startupConfigurations: record.startupConfigurations,
          loginItemsAccess: record.loginItemsAccess,
          residues: record.residues.filter { !ids.contains($0.id) },
          otherCopies: record.otherCopies.filter { !ids.contains($0.id) },
          isRunning: record.isRunning
        )
      }
    case .memory:
      break
    }
  }

  private func removeStartupConfigurations(
    _ ids: Set<ApplicationStartupConfiguration.ID>
  ) {
    guard !ids.isEmpty else { return }
    applications = applications.map { record in
      ApplicationRecord(
        application: record.application,
        bundleIdentifier: record.bundleIdentifier,
        version: record.version,
        startupConfigurations: record.startupConfigurations.filter { !ids.contains($0.id) },
        loginItemsAccess: record.loginItemsAccess,
        residues: record.residues,
        otherCopies: record.otherCopies,
        isRunning: record.isRunning
      )
    }
  }

  private func l(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: language, arguments: arguments)
  }
}

private struct CleanupRequest {
  let tool: MaintenanceTool
  let title: String
  let items: [MaintenanceItem]
  let cacheMode: CacheCleanupMode
  let roots: [URL]

}
