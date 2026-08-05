import AppKit
import CryptoKit
import Darwin
import Foundation

actor MaintenanceService {
  typealias ScanReporter = @Sendable (ScanProgress) async -> Void
  typealias CleanupReporter = @Sendable (CleanupProgress) async -> Void

  private let fileManager = FileManager.default
  private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

  func scanJunk(progress: ScanReporter) async throws -> ScanResult<MaintenanceItem> {
    let library = home.appendingPathComponent("Library", isDirectory: true)
    let definitions: [(URL, MaintenanceItemKind, String)] = [
      (library.appendingPathComponent("Caches"), .cache, "Caches"),
      (library.appendingPathComponent("Logs"), .log, "Logs"),
      (library.appendingPathComponent("DiagnosticReports"), .diagnostic, "Diagnostics"),
      (
        library.appendingPathComponent("Developer/Xcode/DerivedData"),
        .developer,
        "Developer Files"
      ),
      (
        library.appendingPathComponent("Developer/CoreSimulator/Caches"),
        .developer,
        "Developer Files"
      ),
    ]

    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    var scanned = 0
    for (root, kind, category) in definitions where fileManager.fileExists(atPath: root.path) {
      try Task.checkCancellation()
      do {
        let children = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
        for child in children {
          try Task.checkCancellation()
          do {
            let (size, count) = try await pathSize(child)
            let identity = try fileIdentity(child)
            scanned += count
            items.append(
              makeItem(
                kind: kind,
                category: category,
                url: child,
                size: size,
                identity: identity
              ))
            await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            issues.append(Self.scanIssue(at: child, error: error, home: home))
          }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home))
      }
    }
    items.sort { $0.size > $1.size }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanApplications(progress: ScanReporter) async throws -> ScanResult<ApplicationRecord> {
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
    ]
    let runningPaths = await MainActor.run {
      Set(
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
      )
    }
    let currentApplicationPath = await MainActor.run {
      Bundle.main.bundleURL.standardizedFileURL.path
    }
    var applications: [(
      item: MaintenanceItem,
      bundleID: String,
      version: String,
      teamIdentifier: String?
    )] = []
    var issues: [ScanIssue] = []
    var scanned = 0

    for root in roots where fileManager.fileExists(atPath: root.path) {
      var stack: [(URL, Int)] = [(root, 0)]
      while let (directory, depth) = stack.popLast() {
        try Task.checkCancellation()
        guard depth <= 2 else { continue }
        do {
          let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
          )
          for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if child.pathExtension.lowercased() == "app" {
              guard child.standardizedFileURL.path != currentApplicationPath else { continue }
              do {
                let (size, count) = try await pathSize(child)
                let identity = try fileIdentity(child)
                let metadata = applicationMetadata(child)
                scanned += count
                applications.append(
                  (
                    makeItem(
                      kind: .application,
                      category: "Application",
                      name: metadata.name,
                      url: child,
                      size: size,
                      identity: identity,
                      group: metadata.bundleID
                    ),
                    metadata.bundleID,
                    metadata.version,
                    StartupItemCodeSignature.teamIdentifier(at: child)
                  ))
                await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
              } catch is CancellationError {
                throw CancellationError()
              } catch {
                issues.append(Self.scanIssue(at: child, error: error, home: home))
              }
            } else if depth < 2 {
              stack.append((child, depth + 1))
            }
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(Self.scanIssue(at: directory, error: error, home: home))
        }
      }
    }

    let grouped = Dictionary(grouping: applications) { application in
      application.bundleID.isEmpty ? application.item.id : application.bundleID
    }
    let startupApplications = applications.map { application in
      return StartupItemApplication(
        name: application.item.name,
        bundleIdentifier: application.bundleID,
        url: application.item.url,
        teamIdentifier: application.teamIdentifier
      )
    }
    let startupScan = await StartupItemService()
      .scan(applications: startupApplications)
    var records: [ApplicationRecord] = []
    records.reserveCapacity(grouped.count)
    for group in grouped.values {
      try Task.checkCancellation()
      let orderedCopies = group.sorted { lhs, rhs in
        let lhsIsMain = lhs.item.url.path.hasPrefix("/Applications/")
        let rhsIsMain = rhs.item.url.path.hasPrefix("/Applications/")
        if lhsIsMain != rhsIsMain { return lhsIsMain }
        return lhs.item.url.path.localizedStandardCompare(rhs.item.url.path) == .orderedAscending
      }
      guard let application = orderedCopies.first else { continue }
      let residueResult = try await residueItems(
        bundleID: application.bundleID,
        parentID: application.item.id
      )
      issues.append(contentsOf: residueResult.issues)
      let copies = orderedCopies.dropFirst().map(\.item)
      let installedPaths = Set(orderedCopies.map { $0.item.url.standardizedFileURL.path })
      let isRunning = runningPaths.contains { installedPaths.contains($0) }
      let startupConfigurations = applicationStartupConfigurations(
        applicationName: application.item.name,
        bundleIdentifier: application.bundleID,
        teamIdentifier: application.teamIdentifier,
        installedPaths: installedPaths,
        parentID: application.item.id,
        allApplications: startupApplications,
        loginItems: startupScan.loginItems,
        backgroundItems: startupScan.backgroundItems
      )
      records.append(
        ApplicationRecord(
          application: application.item,
          bundleIdentifier: application.bundleID,
          version: application.version,
          startupConfigurations: startupConfigurations,
          loginItemsAccess: startupScan.loginItemsAccess,
          residues: residueResult.items,
          otherCopies: copies,
          isRunning: isRunning
        ))
    }
    records.sort {
      $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
    }
    return ScanResult(values: records, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  private func applicationStartupConfigurations(
    applicationName: String,
    bundleIdentifier: String,
    teamIdentifier: String?,
    installedPaths: Set<String>,
    parentID: String,
    allApplications: [StartupItemApplication],
    loginItems: [SystemLoginItem],
    backgroundItems: [StartupItem]
  ) -> [ApplicationStartupConfiguration] {
    let matchingNameBundleIDs = Set(
      allApplications.filter {
        $0.name.compare(
          applicationName,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
      }.map(\.bundleIdentifier).filter { !$0.isEmpty }
    )
    let teamBundleIDs = Set(
      allApplications.filter {
        teamIdentifier != nil && $0.teamIdentifier == teamIdentifier
      }.map(\.bundleIdentifier).filter { !$0.isEmpty }
    )
    let privilegedHelperLabels = installedPaths.reduce(into: Set<String>()) { labels, path in
      guard let values = Bundle(url: URL(fileURLWithPath: path))?
        .object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: Any]
      else { return }
      labels.formUnion(values.keys)
    }
    let privilegedHelperOwners = allApplications.reduce(
      into: [String: Set<String>]()
    ) { owners, application in
      guard let values = Bundle(url: application.url)?
        .object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: Any]
      else { return }
      let ownerID = application.bundleIdentifier.isEmpty
        ? application.url.standardizedFileURL.path
        : application.bundleIdentifier
      for label in values.keys {
        owners[label, default: []].insert(ownerID)
      }
    }

    var configurations: [ApplicationStartupConfiguration] = []
    for item in loginItems {
      let pathMatches = item.targetURL.map { target in
        installedPaths.contains { applicationPath in
          target.path == applicationPath || target.path.hasPrefix(applicationPath + "/")
        }
      } ?? false
      let nameMatches = item.path == nil
        && item.name.compare(
          applicationName,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
      guard pathMatches || nameMatches else { continue }

      let confidence: StartupAssociationConfidence = pathMatches ? .confirmed : .likely
      let shared = !pathMatches && matchingNameBundleIDs.count > 1
      configurations.append(
        ApplicationStartupConfiguration(
          id: "association:\(item.id)",
          name: item.name,
          source: .loginItem,
          targetPath: item.path,
          loginItem: item,
          launchItem: nil,
          cleanupItems: [],
          confidence: confidence,
          evidence: pathMatches
            ? "Login item target matches the application path."
            : "Login item name matches, but macOS did not report its target path.",
          isShared: shared,
          isDefaultSelected: pathMatches && !shared
        ))
    }

    for item in backgroundItems {
      let executablePath = item.executableURL?.standardizedFileURL.path
      let pathMatches = executablePath.map { executablePath in
        installedPaths.contains { applicationPath in
          executablePath == applicationPath || executablePath.hasPrefix(applicationPath + "/")
        }
      } ?? false
      let bundleMatches = !bundleIdentifier.isEmpty
        && item.requestedBundleIdentifier == bundleIdentifier
      let privilegedHelperMatches = privilegedHelperLabels.contains(item.label)
      let labelMatches = !bundleIdentifier.isEmpty
        && (item.label == bundleIdentifier || item.label.hasPrefix(bundleIdentifier + "."))
      let teamMatches = teamIdentifier != nil
        && item.executableTeamIdentifier == teamIdentifier
      guard pathMatches || bundleMatches || privilegedHelperMatches || labelMatches || teamMatches
      else { continue }

      let confirmed = pathMatches || bundleMatches || privilegedHelperMatches
      let teamOnly = teamMatches && !confirmed && !labelMatches
      let helperShared = privilegedHelperMatches
        && privilegedHelperOwners[item.label, default: []].count > 1
      let shared = helperShared || (teamOnly && teamBundleIDs.count > 1)
      let evidence: String
      if helperShared {
        evidence = "This signed background component may be shared by multiple installed applications."
      } else if pathMatches {
        evidence = "Background task executable is inside the application."
      } else if bundleMatches {
        evidence = "Background task opens this exact application identifier."
      } else if privilegedHelperMatches {
        evidence = "The application explicitly declares this privileged helper."
      } else if labelMatches {
        evidence = "Background task label begins with the application identifier."
      } else {
        evidence = shared
          ? "This signed background component may be shared by multiple installed applications."
          : "Background task and application use the same signing team."
      }

      var cleanupItems: [MaintenanceItem] = []
      if let identity = try? fileIdentity(item.plistURL) {
        cleanupItems.append(
          makeItem(
            kind: .startupItem,
            category: "Startup Item",
            name: item.label,
            url: item.plistURL,
            size: identity.size,
            identity: identity,
            group: bundleIdentifier,
            parentID: parentID
          ))
      }
      if privilegedHelperMatches, !shared,
        let executableURL = item.executableURL,
        executableURL.standardizedFileURL.path.hasPrefix("/Library/PrivilegedHelperTools/"),
        executableURL.lastPathComponent == item.label,
        let teamIdentifier,
        item.executableTeamIdentifier == teamIdentifier,
        let identity = try? fileIdentity(executableURL)
      {
        cleanupItems.append(
          makeItem(
            kind: .startupItem,
            category: "Privileged Helper",
            name: executableURL.lastPathComponent,
            url: executableURL,
            size: identity.size,
            identity: identity,
            group: bundleIdentifier,
            parentID: parentID
          ))
      }
      configurations.append(
        ApplicationStartupConfiguration(
          id: "association:launchd:\(item.id)",
          name: item.label,
          source: startupConfigurationSource(for: item.kind),
          targetPath: item.executableURL?.path,
          loginItem: nil,
          launchItem: item,
          cleanupItems: cleanupItems,
          confidence: confirmed ? .confirmed : .likely,
          evidence: evidence,
          isShared: shared,
          isDefaultSelected: confirmed && !shared && !cleanupItems.isEmpty
        ))
    }

    return configurations.sorted { lhs, rhs in
      if lhs.isShared != rhs.isShared { return !lhs.isShared }
      if lhs.confidence != rhs.confidence { return lhs.confidence == .confirmed }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  private func startupConfigurationSource(
    for kind: StartupItemKind
  ) -> StartupConfigurationSource {
    switch kind {
    case .userAgent: .userLaunchAgent
    case .globalAgent: .globalLaunchAgent
    case .daemon: .systemDaemon
    }
  }

  func scanLargeFiles(
    roots: [URL],
    thresholdMB: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let threshold = UInt64(thresholdMB) * 1_024 * 1_024
    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    var scanned = 0
    for root in safeScanRoots(roots) {
      do {
        _ = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home, configuredRoot: true))
        continue
      }
      let scanHome = home
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) { url, error in
        issues.append(Self.scanIssue(at: url, error: error, home: scanHome, configuredRoot: true))
        return true
      }
      while let file = enumerator?.nextObject() as? URL {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        if values.isSymbolicLink == true {
          enumerator?.skipDescendants()
          continue
        }
        guard values.isRegularFile == true else { continue }
        scanned += 1
        if scanned.isMultiple(of: 100) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: file.path))
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size >= threshold else { continue }
        let identity = try fileIdentity(file)
        items.append(
          makeItem(
            kind: .largeFile,
            category: "Large File",
            url: file,
            size: size,
            identity: identity
          ))
      }
    }
    items.sort { $0.size > $1.size }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanDuplicates(
    roots: [URL],
    minimumMB: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let minimum = UInt64(minimumMB) * 1_024 * 1_024
    var bySize: [UInt64: [URL]] = [:]
    var issues: [ScanIssue] = []
    var scanned = 0
    var identities = Set<String>()

    for root in safeScanRoots(roots) {
      do {
        _ = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home, configuredRoot: true))
        continue
      }
      let scanHome = home
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) { url, error in
        issues.append(Self.scanIssue(at: url, error: error, home: scanHome, configuredRoot: true))
        return true
      }
      while let file = enumerator?.nextObject() as? URL {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        if values.isSymbolicLink == true {
          enumerator?.skipDescendants()
          continue
        }
        guard values.isRegularFile == true else { continue }
        scanned += 1
        if scanned.isMultiple(of: 100) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: file.path))
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size >= minimum else { continue }
        let identity = try fileIdentity(file)
        let identityKey = "\(identity.device):\(identity.inode)"
        guard identities.insert(identityKey).inserted else { continue }
        bySize[size, default: []].append(file)
      }
    }

    var items: [MaintenanceItem] = []
    for (size, candidates) in bySize where candidates.count > 1 {
      var byHash: [String: [URL]] = [:]
      for candidate in candidates {
        try Task.checkCancellation()
        do {
          let digest = try await hashFile(candidate)
          byHash[digest, default: []].append(candidate)
          await progress(ScanProgress(scannedCount: scanned, currentPath: candidate.path))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(
            Self.scanIssue(at: candidate, error: error, home: home, configuredRoot: true)
          )
        }
      }
      for (digest, duplicates) in byHash where duplicates.count > 1 {
        for duplicate in duplicates.sorted(by: { $0.path < $1.path }) {
          let identity = try fileIdentity(duplicate)
          items.append(
            makeItem(
              kind: .duplicate,
              category: "Duplicate",
              url: duplicate,
              size: size,
              identity: identity,
              group: String(digest.prefix(12))
            ))
        }
      }
    }
    items.sort { lhs, rhs in
      lhs.group == rhs.group ? lhs.url.path < rhs.url.path : lhs.size > rhs.size
    }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanDownloads(
    olderThanDays: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let root = home.appendingPathComponent("Downloads", isDirectory: true)
    var issues: [ScanIssue] = []
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles]
      )
    } catch {
      let issue = Self.scanIssue(at: root, error: error, home: home, configuredRoot: true)
      return ScanResult(values: [], issues: [issue], scannedCount: 0)
    }

    var candidates: [DownloadCandidate] = []
    var scanned = 0
    for child in children {
      try Task.checkCancellation()
      do {
        let values = try child.resourceValues(forKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let size = UInt64(max(0, values.fileSize ?? 0))
        let modified = values.contentModificationDate ?? .distantPast
        candidates.append(DownloadCandidate(url: child, size: size, modified: modified))
        scanned += 1
        if scanned.isMultiple(of: 20) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
        }
      } catch {
        issues.append(Self.scanIssue(at: child, error: error, home: home, configuredRoot: true))
      }
    }

    var duplicateHashes: [String: String] = [:]
    let candidatesBySize = Dictionary(grouping: candidates.filter { $0.size > 0 }, by: \.size)
    for sameSize in candidatesBySize.values where sameSize.count > 1 {
      var filesByHash: [String: [DownloadCandidate]] = [:]
      for candidate in sameSize {
        try Task.checkCancellation()
        do {
          let digest = try await hashFile(candidate.url)
          filesByHash[digest, default: []].append(candidate)
          await progress(ScanProgress(scannedCount: scanned, currentPath: candidate.url.path))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(
            Self.scanIssue(at: candidate.url, error: error, home: home, configuredRoot: true)
          )
        }
      }
      for (digest, matches) in filesByHash where matches.count > 1 {
        for match in matches {
          duplicateHashes[match.url.standardizedFileURL.path] = digest
        }
      }
    }

    let cutoff = Date().addingTimeInterval(-Double(max(1, olderThanDays)) * 86_400)
    let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
    let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"]
    let incompleteExtensions: Set<String> = ["download", "crdownload", "part"]
    var items: [MaintenanceItem] = []

    for candidate in candidates {
      let path = candidate.url.standardizedFileURL.path
      let fileExtension = candidate.url.pathExtension.lowercased()
      let category: String
      let group: String
      if let digest = duplicateHashes[path] {
        category = "Duplicate Download"
        group = String(digest.prefix(12))
      } else if incompleteExtensions.contains(fileExtension) {
        category = "Incomplete Download"
        group = ""
      } else if installerExtensions.contains(fileExtension) {
        category = "Installer"
        group = ""
      } else if archiveExtensions.contains(fileExtension) {
        category = "Archive"
        group = ""
      } else if candidate.size >= 1_024 * 1_024 * 1_024 {
        category = "Large Download"
        group = ""
      } else if candidate.modified < cutoff {
        category = "Old Download"
        group = ""
      } else {
        continue
      }

      do {
        let identity = try fileIdentity(candidate.url)
        items.append(
          makeItem(
            kind: .download,
            category: category,
            url: candidate.url,
            size: candidate.size,
            identity: identity,
            group: group
          )
        )
      } catch {
        issues.append(
          Self.scanIssue(at: candidate.url, error: error, home: home, configuredRoot: true)
        )
      }
    }

    items.sort { lhs, rhs in
      if lhs.category != rhs.category {
        return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
      }
      if lhs.size != rhs.size { return lhs.size > rhs.size }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func cleanup(
    items: [MaintenanceItem],
    cacheMode: CacheCleanupMode,
    allowedRoots: [URL],
    authorize: Bool,
    progress: CleanupReporter
  ) async -> CleanupResult {
    let ordered = items.enumerated().sorted { lhs, rhs in
      let lhsRank = cleanupRank(lhs.element)
      let rhsRank = cleanupRank(rhs.element)
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    var completedItems: [MaintenanceItem] = []
    var failures: [MaintenanceFailure] = []
    var handledBytes: UInt64 = 0
    var processedCount = 0
    var handledAuthorizedIDs = Set<MaintenanceItem.ID>()

    for item in ordered {
      if Task.isCancelled { break }
      if handledAuthorizedIDs.contains(item.id) { continue }

      if authorize, requiresAdministratorRemoval(item) {
        let candidates = ordered.filter {
          !handledAuthorizedIDs.contains($0.id) && requiresAdministratorRemoval($0)
        }
        handledAuthorizedIDs.formUnion(candidates.map(\.id))
        var authorizedItems: [MaintenanceItem] = []
        for candidate in candidates {
          do {
            try validate(candidate, allowedRoots: allowedRoots)
            if candidate.kind == .application, await applicationIsRunning(candidate.url) {
              throw MaintenanceServiceError.running
            }
            authorizedItems.append(candidate)
          } catch {
            let failure = classifyFailure(item: candidate, error: error)
            failures.append(failure)
            processedCount += 1
            await progress(
              CleanupProgress(
                completed: processedCount,
                total: ordered.count,
                item: candidate,
                state: .failed,
                detail: failure.detail
              ))
          }
        }
        guard !authorizedItems.isEmpty else { continue }

        await progress(
          CleanupProgress(
            completed: processedCount,
            total: ordered.count,
            item: authorizedItems[0],
            state: .working,
            detail: ""
          ))
        let authorizationResult = SystemPermission
          .moveItemsToTrashWithAdministratorAuthorization(
            authorizedItems.map(administratorTrashItem(for:))
          )
        switch authorizationResult {
        case .success:
          for candidate in authorizedItems {
            if candidate.kind == .application {
              SystemPermission.unregisterApplication(at: candidate.url)
            }
            completedItems.append(candidate)
            handledBytes += candidate.size
            processedCount += 1
            await progress(
              CleanupProgress(
                completed: processedCount,
                total: ordered.count,
                item: candidate,
                state: .completed,
                detail: "Moved to Trash"
              ))
          }
        case .cancelled:
          await progress(
            CleanupProgress(
              completed: processedCount,
              total: ordered.count,
              item: authorizedItems[0],
              state: .failed,
              detail: "Cancelled"
            ))
          return CleanupResult(
            completed: completedItems,
            failures: failures,
            reclaimedBytes: handledBytes,
            authorizationCancelled: true
          )
        case .failure(let message):
          for candidate in authorizedItems {
            let failure = classifyFailure(
              item: candidate,
              error: MaintenanceServiceError.administratorAuthorizationFailed(message)
            )
            failures.append(failure)
            processedCount += 1
            await progress(
              CleanupProgress(
                completed: processedCount,
                total: ordered.count,
                item: candidate,
                state: .failed,
                detail: failure.detail
              ))
          }
        }
        continue
      }

      await progress(
        CleanupProgress(
          completed: processedCount,
          total: ordered.count,
          item: item,
          state: .working,
          detail: ""
        ))
      do {
        try validate(item, allowedRoots: allowedRoots)
        if item.kind == .application, await applicationIsRunning(item.url) {
          throw MaintenanceServiceError.running
        }

        let permanentlyDelete =
          cacheMode == .delete
          && (item.kind == .cache || item.kind == .developer)
        if item.kind == .startupItem, item.url.pathExtension == "plist" {
          stopStartupItem(at: item.url)
        }
        if permanentlyDelete {
          try fileManager.removeItem(at: item.url)
        } else {
          try fileManager.trashItem(at: item.url, resultingItemURL: nil)
        }
        if item.kind == .application {
          SystemPermission.unregisterApplication(at: item.url)
        }
        completedItems.append(item)
        handledBytes += item.size
        processedCount += 1
        await progress(
          CleanupProgress(
            completed: processedCount,
            total: ordered.count,
            item: item,
            state: .completed,
            detail: permanentlyDelete ? "Deleted" : "Moved to Trash"
          ))
      } catch {
        let failure = classifyFailure(item: item, error: error)
        failures.append(failure)
        processedCount += 1
        await progress(
          CleanupProgress(
            completed: processedCount,
            total: ordered.count,
            item: item,
            state: .failed,
            detail: failure.detail
          ))
      }
    }
    return CleanupResult(
      completed: completedItems,
      failures: failures,
      reclaimedBytes: handledBytes,
      authorizationCancelled: false
    )
  }

  func preflightCleanup(
    items: [MaintenanceItem],
    allowedRoots: [URL]
  ) async -> [MaintenanceFailure] {
    var failures: [MaintenanceFailure] = []
    for item in items {
      do {
        try validate(item, allowedRoots: allowedRoots)
        if item.kind == .application, await applicationIsRunning(item.url) {
          throw MaintenanceServiceError.running
        }
      } catch {
        failures.append(classifyFailure(item: item, error: error))
      }
    }
    return failures
  }

  private func cleanupRank(_ item: MaintenanceItem) -> Int {
    switch item.kind {
    case .startupItem:
      return requiresAdministratorRemoval(item) ? 1 : 0
    case .application:
      return 2
    default:
      return 3
    }
  }

  private func requiresAdministratorRemoval(_ item: MaintenanceItem) -> Bool {
    let path = item.url.standardizedFileURL.path
    if item.kind == .application {
      return path.hasPrefix("/Applications/")
    }
    guard item.kind == .startupItem else { return false }
    return path.hasPrefix("/Library/LaunchAgents/")
      || path.hasPrefix("/Library/LaunchDaemons/")
      || path.hasPrefix("/Library/PrivilegedHelperTools/")
  }

  private func administratorTrashItem(for item: MaintenanceItem) -> AdministratorTrashItem {
    AdministratorTrashItem(
      source: item.url,
      serviceTarget: item.kind == .startupItem && item.url.pathExtension == "plist"
        ? startupServiceTarget(at: item.url)
        : nil
    )
  }

  private func stopStartupItem(at url: URL) {
    guard let target = startupServiceTarget(at: url) else { return }
    _ = runLaunchctl(["bootout", target])
    _ = runLaunchctl(["enable", target])
  }

  private func startupServiceTarget(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ),
      let dictionary = propertyList as? [String: Any],
      let label = dictionary["Label"] as? String,
      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    let path = url.standardizedFileURL.path
    let domain = path.hasPrefix("/Library/LaunchDaemons/")
      ? "system"
      : "gui/\(getuid())"
    return "\(domain)/\(label)"
  }

  private func runLaunchctl(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  func releaseMemory() -> MemoryReleaseResult {
    guard fileManager.isExecutableFile(atPath: "/usr/bin/purge") else {
      return .failure("The purge utility is unavailable on this version of macOS.")
    }
    switch SystemPermission.purgeFileCacheWithAdministratorAuthorization() {
    case .success: return .success
    case .cancelled: return .cancelled
    case .failure(let message): return .failure(message)
    }
  }

  private func residueItems(bundleID: String, parentID: String) async throws
    -> (items: [MaintenanceItem], issues: [ScanIssue])
  {
    guard !bundleID.isEmpty else { return ([], []) }
    let library = home.appendingPathComponent("Library", isDirectory: true)
    let candidates: [(URL, String)] = [
      (library.appendingPathComponent("Caches/\(bundleID)"), "Cache"),
      (library.appendingPathComponent("Preferences/\(bundleID).plist"), "Preferences"),
      (
        library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        "Saved State"
      ),
      (library.appendingPathComponent("Application Support/\(bundleID)"), "Application Support"),
      (library.appendingPathComponent("Containers/\(bundleID)"), "Container"),
      (library.appendingPathComponent("HTTPStorages/\(bundleID)"), "Web Data"),
      (library.appendingPathComponent("WebKit/\(bundleID)"), "Web Data"),
    ]
    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    for (url, category) in candidates {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      do {
        let (size, _) = try await pathSize(url)
        let identity = try fileIdentity(url)
        items.append(
          makeItem(
            kind: .residue,
            category: category,
            url: url,
            size: size,
            identity: identity,
            group: bundleID,
            parentID: parentID
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(Self.scanIssue(at: url, error: error, home: home))
      }
    }
    return (items, issues)
  }

  private func applicationMetadata(_ url: URL) -> (bundleID: String, name: String, version: String)
  {
    let bundle = Bundle(url: url)
    let identifier = bundle?.bundleIdentifier ?? ""
    let name =
      bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? url.deletingPathExtension().lastPathComponent
    let version =
      bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return (identifier, name, version)
  }

  private func makeItem(
    kind: MaintenanceItemKind,
    category: String,
    name: String? = nil,
    url: URL,
    size: UInt64,
    identity: FileIdentity,
    group: String = "",
    parentID: String? = nil
  ) -> MaintenanceItem {
    MaintenanceItem(
      kind: kind,
      category: category,
      name: name,
      url: url.standardizedFileURL,
      size: size,
      modified: Date(timeIntervalSince1970: identity.modified),
      identity: identity,
      group: group,
      parentID: parentID
    )
  }

  private func pathSize(_ url: URL) async throws -> (UInt64, Int) {
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      return (UInt64(max(0, values.fileSize ?? 0)), 1)
    }
    var total: UInt64 = 0
    var count = 0
    let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [
        .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]
    )
    var visited = 0
    while let child = enumerator?.nextObject() as? URL {
      visited += 1
      if visited.isMultiple(of: 256) {
        try Task.checkCancellation()
        await Task.yield()
      }
      guard let childValues = try? child.resourceValues(forKeys: [
          .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]) else { continue }
      if childValues.isSymbolicLink == true {
        enumerator?.skipDescendants()
        continue
      }
      guard childValues.isRegularFile == true else { continue }
      total += UInt64(max(0, childValues.fileAllocatedSize ?? childValues.fileSize ?? 0))
      count += 1
    }
    return (total, max(1, count))
  }

  private func fileIdentity(_ url: URL) throws -> FileIdentity {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return FileIdentity(
      device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
      size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    )
  }

  private func hashFile(_ url: URL) async throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
      await Task.yield()
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func safeScanRoots(_ roots: [URL]) -> [URL] {
    roots.map(\.standardizedFileURL).filter { root in
      root.path != "/"
        && root.path != "/System"
        && !root.path.hasPrefix("/System/")
        && root.path != "/Library"
        && !root.path.hasPrefix("/Library/")
    }
  }

  private static func scanIssue(
    at url: URL,
    error: Error,
    home: URL,
    configuredRoot: Bool = false
  ) -> ScanIssue {
    let errors = errorChain(error as NSError)
    let isUnavailable = errors.contains { error in
      (error.domain == NSCocoaErrorDomain
        && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
    let isPermissionDenied = errors.contains { error in
      (error.domain == NSCocoaErrorDomain
        && (error.code == NSFileReadNoPermissionError
          || error.code == NSFileWriteNoPermissionError))
        || (error.domain == NSPOSIXErrorDomain
          && (error.code == Int(EACCES) || error.code == Int(EPERM)))
    }

    let kind: ScanIssueKind
    if isUnavailable {
      kind = .unavailable
    } else if isPermissionDenied
      && filesAndFoldersRoots(home: home).contains(where: { contains(url, in: $0) })
    {
      kind = .filesAndFolders
    } else if isPermissionDenied
      && contains(url, in: home.appendingPathComponent("Library", isDirectory: true))
    {
      kind = .fullDiskAccess
    } else if isPermissionDenied && configuredRoot {
      kind = .folderAccess
    } else {
      kind = .other
    }

    return ScanIssue(
      url: url.standardizedFileURL,
      kind: kind,
      detail: error.localizedDescription
    )
  }

  private static func filesAndFoldersRoots(home: URL) -> [URL] {
    ["Desktop", "Documents", "Downloads"].map {
      home.appendingPathComponent($0, isDirectory: true).standardizedFileURL
    }
  }

  private static func contains(_ url: URL, in root: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private static func errorChain(_ error: NSError) -> [NSError] {
    var errors: [NSError] = []
    var nextError: NSError? = error
    while let current = nextError {
      errors.append(current)
      nextError = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return errors
  }

  private func uniqueIssues(_ issues: [ScanIssue]) -> [ScanIssue] {
    var ids = Set<ScanIssue.ID>()
    return issues.filter { ids.insert($0.id).inserted }
  }

  private func validate(_ item: MaintenanceItem, allowedRoots: [URL]) throws {
    guard fileManager.fileExists(atPath: item.url.path) else {
      throw MaintenanceServiceError.notFound
    }
    let path = item.url.standardizedFileURL.path
    let roots = allowedRoots.map(\.standardizedFileURL.path)
    let isAllowed = roots.contains { root in
      path != root && path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    guard isAllowed, !path.hasPrefix("/System/") else {
      throw MaintenanceServiceError.outsideScope
    }
    guard try fileIdentity(item.url) == item.identity else {
      throw MaintenanceServiceError.changed
    }
  }

  private func applicationIsRunning(_ url: URL) async -> Bool {
    await MainActor.run {
      NSWorkspace.shared.runningApplications.contains { application in
        guard let bundleURL = application.bundleURL?.standardizedFileURL else { return false }
        return bundleURL == url.standardizedFileURL
          || bundleURL.path.hasPrefix(url.standardizedFileURL.path + "/")
      }
    }
  }

  private func classifyFailure(item: MaintenanceItem, error: Error) -> MaintenanceFailure {
    if let serviceError = error as? MaintenanceServiceError {
      return MaintenanceFailure(
        item: item,
        kind: serviceError.failureKind,
        detail: serviceError.localizedDescription
      )
    }
    let cocoaError = error as NSError
    let permissionDenied =
      cocoaError.code == NSFileWriteNoPermissionError
      || cocoaError.code == Int(EACCES)
      || cocoaError.code == Int(EPERM)
      || cocoaError.localizedDescription.localizedCaseInsensitiveContains("permission")
      || cocoaError.localizedDescription.localizedCaseInsensitiveContains("not permitted")
    let kind: MaintenanceFailureKind
    if permissionDenied,
      item.url.standardizedFileURL.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
    {
      kind = .fullDiskAccess
    } else if permissionDenied,
      Self.filesAndFoldersRoots(home: home).contains(where: { Self.contains(item.url, in: $0) })
    {
      kind = .filesAndFolders
    } else if permissionDenied, item.kind == .application,
      item.url.path.hasPrefix("/Applications/")
    {
      kind = .administratorRequired
    } else if permissionDenied {
      kind = .permission
    } else {
      kind = .operationFailed
    }
    return MaintenanceFailure(item: item, kind: kind, detail: error.localizedDescription)
  }
}

private struct DownloadCandidate: Sendable {
  let url: URL
  let size: UInt64
  let modified: Date
}

private enum MaintenanceServiceError: LocalizedError {
  case notFound
  case changed
  case outsideScope
  case running
  case administratorAuthorizationFailed(String)

  var errorDescription: String? {
    switch self {
    case .notFound: "The item no longer exists."
    case .changed: "The item changed after it was scanned. Scan again before removing it."
    case .outsideScope: "The item is outside the allowed cleanup folders."
    case .running: "Quit the application before uninstalling it."
    case .administratorAuthorizationFailed(let message): message
    }
  }

  var failureKind: MaintenanceFailureKind {
    switch self {
    case .notFound: .notFound
    case .changed: .changed
    case .outsideScope: .outsideScope
    case .running: .running
    case .administratorAuthorizationFailed: .administratorRequired
    }
  }
}
