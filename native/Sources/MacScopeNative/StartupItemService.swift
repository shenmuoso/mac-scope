import AppKit
import Foundation
import Security
import ServiceManagement

actor StartupItemService {
  private let fileManager = FileManager.default
  private let home: URL
  private let userID: uid_t

  init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    userID: uid_t = getuid()
  ) {
    self.home = home.standardizedFileURL
    self.userID = userID
  }

  func scan(
    applications suppliedApplications: [StartupItemApplication]? = nil,
    includeLoginItems: Bool = true
  ) -> StartupItemScanResult {
    let applications = suppliedApplications ?? installedApplications()
    let userDisabled = disabledServices(in: "gui/\(userID)")
    let systemDisabled = disabledServices(in: "system")
    let roots: [(url: URL, kind: StartupItemKind)] = [
      (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), .userAgent),
      (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .globalAgent),
      (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .daemon),
    ]

    var items: [StartupItem] = []
    var issues: [String] = []
    for root in roots where fileManager.fileExists(atPath: root.url.path) {
      do {
        let files = try fileManager.contentsOfDirectory(
          at: root.url,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
        for plistURL in files where plistURL.pathExtension.lowercased() == "plist" {
          do {
            let values = try plistURL.resourceValues(forKeys: [
              .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: plistURL)
            let provisional = try StartupItemParser.parse(
              data: data,
              plistURL: plistURL,
              kind: root.kind,
              applications: applications,
              home: home,
              fileExists: { self.fileManager.fileExists(atPath: $0.path) },
              teamIdentifier: StartupItemCodeSignature.teamIdentifier(at:)
            )
            let disabled = (root.kind == .daemon ? systemDisabled : userDisabled)[provisional.label]
            let serviceStatus = SMAppService.statusForLegacyPlist(at: plistURL)
            let permissionState = permissionState(
              hasValidLabel: provisional.hasValidLabel,
              disabledOverride: disabled,
              serviceStatus: serviceStatus
            )
            let runtimeResult = provisional.hasValidLabel
              ? runLaunchctl(
                ["print", serviceTarget(for: provisional)],
                capturesOutput: true
              )
              : (status: Int32(1), output: "")
            let runtimeState = Self.runtimeState(
              launchctlStatus: runtimeResult.status,
              output: runtimeResult.output,
              permissionState: permissionState
            )
            items.append(
              provisional.replacing(
                permissionState: permissionState,
                runtimeState: runtimeState
              )
            )
          } catch {
            issues.append("\(plistURL.path): \(error.localizedDescription)")
          }
        }
      } catch {
        issues.append("\(root.url.path): \(error.localizedDescription)")
      }
    }

    items.sort { lhs, rhs in
      if lhs.residueState != rhs.residueState {
        return Self.residueRank(lhs.residueState) > Self.residueRank(rhs.residueState)
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    let loginScan = includeLoginItems
      ? scanLoginItems(applications: applications)
      : (items: [], access: LoginItemsAccessState.available, issue: nil)
    if let issue = loginScan.issue {
      issues.append(issue)
    }
    return StartupItemScanResult(
      loginItems: loginScan.items,
      backgroundItems: items,
      loginItemsAccess: loginScan.access,
      issues: issues
    )
  }

  func setStartupAllowed(_ allowStartup: Bool, for item: StartupItem) async
    -> StartupItemOperationResult
  {
    guard item.hasValidLabel else {
      return .failure("This startup item does not contain a valid launchd label.")
    }
    guard isAllowed(item.plistURL, kind: item.kind) else {
      return .failure("The startup item is outside the supported launchd folders.")
    }

    let domain = serviceDomain(for: item.kind)
    let target = item.hasValidLabel ? serviceTarget(for: item) : ""
    if item.kind.requiresAdministrator {
      await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
      return administratorResult(
        SystemPermission.setStartupItemEnabledWithAdministratorAuthorization(
          allowStartup,
          serviceTarget: target,
          domain: domain,
          plistURL: item.plistURL
        )
      )
    }

    if allowStartup {
      guard launchctlSucceeds(["enable", target]) else {
        return .failure("macOS could not enable this startup item.")
      }
      let needsBootstrap: Bool
      switch item.runtimeState {
      case .unloaded, .disabled:
        needsBootstrap = true
      default:
        needsBootstrap = false
      }
      if needsBootstrap {
        if !launchctlSucceeds(["bootstrap", domain, item.plistURL.path]) {
          return .failure("macOS allowed startup but could not load the task.")
        }
      }
    } else {
      guard launchctlSucceeds(["disable", target]) else {
        return .failure("macOS could not disable this startup item.")
      }
      _ = launchctlSucceeds(["bootout", target])
    }
    return .success
  }

  func addLoginItem(at applicationURL: URL) -> StartupItemOperationResult {
    let url = applicationURL.standardizedFileURL
    guard url.pathExtension.lowercased() == "app",
      fileManager.fileExists(atPath: url.path)
    else {
      return .failure("Choose an installed application to open at login.")
    }
    let result = runAppleScript(
      [
        "on run argv",
        "tell application \"System Events\"",
        "make login item at end with properties {path:item 1 of argv, hidden:false}",
        "end tell",
        "end run",
      ],
      arguments: [url.path]
    )
    return loginItemOperationResult(result)
  }

  func removeLoginItem(_ item: SystemLoginItem) -> StartupItemOperationResult {
    let result = runAppleScript(
      [
        "on run argv",
        "set itemName to item 1 of argv",
        "set expectedPath to item 2 of argv",
        "tell application \"System Events\"",
        "set matchingItems to every login item whose name is itemName",
        "if expectedPath is \"\" and (count matchingItems) is greater than 1 then error \"Multiple unresolved login items have this name. Remove the intended item in System Settings.\"",
        "repeat with candidate in matchingItems",
        "set candidatePath to \"\"",
        "try",
        "set candidatePath to path of candidate",
        "end try",
        "if expectedPath is \"\" or candidatePath is expectedPath then",
        "delete candidate",
        "return",
        "end if",
        "end repeat",
        "end tell",
        "error \"The login item is no longer present.\"",
        "end run",
      ],
      arguments: [item.name, item.path ?? ""]
    )
    return loginItemOperationResult(result)
  }

  func remove(_ item: StartupItem) async -> StartupItemOperationResult {
    guard item.canRemove else {
      return .failure("Only detected startup remnants can be removed here.")
    }
    guard item.hasValidLabel || item.permissionState == .unavailable else {
      return .failure("The startup item could not be identified safely.")
    }
    guard isAllowed(item.plistURL, kind: item.kind) else {
      return .failure("The startup item is outside the supported launchd folders.")
    }

    let target = item.hasValidLabel ? serviceTarget(for: item) : ""
    if item.kind.requiresAdministrator {
      await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
      return administratorResult(
        SystemPermission.removeStartupItemWithAdministratorAuthorization(
          serviceTarget: target,
          plistURL: item.plistURL
        )
      )
    }

    if item.hasValidLabel {
      _ = launchctlSucceeds(["bootout", target])
      _ = launchctlSucceeds(["enable", target])
    }
    do {
      try fileManager.trashItem(at: item.plistURL, resultingItemURL: nil)
      return .success
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  private func permissionState(
    hasValidLabel: Bool,
    disabledOverride: Bool?,
    serviceStatus: SMAppService.Status
  ) -> StartupItemPermissionState {
    guard hasValidLabel else { return .unavailable }
    if serviceStatus == .requiresApproval { return .requiresApproval }
    if disabledOverride == true { return .disabled }
    return .allowed
  }

  static func runtimeState(
    launchctlStatus: Int32,
    output: String,
    permissionState: StartupItemPermissionState
  ) -> StartupItemRuntimeState {
    switch permissionState {
    case .disabled: return .disabled
    case .requiresApproval: return .requiresApproval
    case .unavailable: return .unavailable
    case .allowed: break
    }
    guard launchctlStatus == 0 else { return .unloaded }

    let state = capture(in: output, pattern: #"(?m)^\s*state\s*=\s*([^\s]+)"#)?
      .lowercased()
    let pid = capture(in: output, pattern: #"(?m)^\s*pid\s*=\s*(\d+)"#)
      .flatMap(Int32.init)
    if state == "running" {
      return .running(pid: pid)
    }
    return .waiting
  }

  private static func capture(in value: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else {
      return nil
    }
    return String(value[range])
  }

  private func disabledServices(in domain: String) -> [String: Bool] {
    let result = runLaunchctl(["print-disabled", domain], capturesOutput: true)
    guard result.status == 0 else { return [:] }
    return Self.parseDisabledServices(result.output)
  }

  static func parseDisabledServices(_ output: String) -> [String: Bool] {
    var services: [String: Bool] = [:]
    for line in output.split(whereSeparator: \Character.isNewline) {
      let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let separator = text.range(of: "=>") else { continue }
      var label = text[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
      if label.hasPrefix("\"") && label.hasSuffix("\"") {
        label.removeFirst()
        label.removeLast()
      }
      let value = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("disabled") {
        services[label] = true
      } else if value.hasPrefix("enabled") {
        services[label] = false
      }
    }
    return services
  }

  private func scanLoginItems(
    applications: [StartupItemApplication]
  ) -> (items: [SystemLoginItem], access: LoginItemsAccessState, issue: String?) {
    let script = """
      function run() {
        const systemEvents = Application("System Events");
        const values = systemEvents.loginItems().map(function(item) {
          let itemPath = null;
          let hidden = false;
          try {
            const rawPath = item.path();
            if (rawPath !== null && rawPath !== undefined) {
              itemPath = String(rawPath);
            }
          } catch (_) {}
          try { hidden = Boolean(item.hidden()); } catch (_) {}
          return { name: String(item.name()), path: itemPath, hidden: hidden };
        });
        return JSON.stringify(values);
      }
      """
    let result = runOSAScript(language: "JavaScript", source: script, arguments: [])
    guard result.status == 0 else {
      let lowered = result.message.lowercased()
      if lowered.contains("-1743") || lowered.contains("not authorized")
        || lowered.contains("不允许")
      {
        return ([], .denied, "Automation access to login items was denied.")
      }
      let message = result.message.isEmpty
        ? "macOS could not read Login Items."
        : result.message
      return ([], .unavailable(message), message)
    }

    do {
      let items = try Self.parseLoginItemsJSON(
        result.message,
        applications: applications,
        fileExists: { self.fileManager.fileExists(atPath: $0.path) }
      )
      return (items, .available, nil)
    } catch {
      return ([], .unavailable(error.localizedDescription), error.localizedDescription)
    }
  }

  static func parseLoginItemsJSON(
    _ output: String,
    applications: [StartupItemApplication],
    fileExists: (URL) -> Bool
  ) throws -> [SystemLoginItem] {
    let payloads = try JSONDecoder().decode(
      [SystemLoginItemPayload].self,
      from: Data(output.utf8)
    )
    var occurrences: [String: Int] = [:]
    return payloads.map { payload in
      let normalizedPath = payload.path?.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = normalizedPath.flatMap { $0.isEmpty || $0 == "missing value" ? nil : $0 }
      let targetURL = path.map { URL(fileURLWithPath: $0).standardizedFileURL }
      let application = applications.first { candidate in
        guard let targetURL else {
          return candidate.name.compare(
            payload.name,
            options: [.caseInsensitive, .diacriticInsensitive]
          ) == .orderedSame
        }
        let targetPath = targetURL.path
        let applicationPath = candidate.url.standardizedFileURL.path
        return targetPath == applicationPath || targetPath.hasPrefix(applicationPath + "/")
      }
      let residueState: StartupItemResidueState
      if let targetURL {
        residueState = fileExists(targetURL) ? .none : .confirmed
      } else {
        residueState = application == nil ? .suspected : .none
      }

      let baseID = "login:\(payload.name):\(path ?? "unresolved")"
      let occurrence = occurrences[baseID, default: 0]
      occurrences[baseID] = occurrence + 1
      return SystemLoginItem(
        id: occurrence == 0 ? baseID : "\(baseID):\(occurrence)",
        name: payload.name,
        path: path,
        isHidden: payload.hidden,
        applicationURL: application?.url,
        residueState: residueState
      )
    }
    .sorted {
      if $0.residueState != $1.residueState {
        return residueRank($0.residueState) > residueRank($1.residueState)
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func runAppleScript(
    _ statements: [String],
    arguments: [String]
  ) -> (status: Int32, message: String) {
    runOSAScript(
      language: "AppleScript",
      arguments: statements.flatMap { ["-e", $0] } + arguments
    )
  }

  private func runOSAScript(
    language: String,
    source: String? = nil,
    arguments: [String]
  ) -> (status: Int32, message: String) {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    var processArguments = language == "JavaScript" ? ["-l", "JavaScript"] : []
    if let source {
      processArguments += ["-e", source]
    }
    process.arguments = processArguments + arguments
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      return (1, error.localizedDescription)
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let messageData = errorData.isEmpty ? outputData : errorData
    let message = String(data: messageData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, message)
  }

  private func loginItemOperationResult(
    _ result: (status: Int32, message: String)
  ) -> StartupItemOperationResult {
    if result.status == 0 { return .success }
    if result.message.contains("(-128)") { return .cancelled }
    return .failure(
      result.message.isEmpty ? "macOS could not update Login Items." : result.message
    )
  }

  private func installedApplications() -> [StartupItemApplication] {
    let roots: [(URL, Int)] = [
      (URL(fileURLWithPath: "/Applications", isDirectory: true), 2),
      (home.appendingPathComponent("Applications", isDirectory: true), 2),
      (URL(fileURLWithPath: "/System/Applications", isDirectory: true), 1),
    ]
    var applications: [StartupItemApplication] = []
    var seenPaths = Set<String>()
    for (root, maximumDepth) in roots where fileManager.fileExists(atPath: root.path) {
      var stack: [(URL, Int)] = [(root, 0)]
      while let (directory, depth) = stack.popLast() {
        guard depth <= maximumDepth,
          let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
          )
        else {
          continue
        }
        for child in children {
          guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            continue
          }
          if child.pathExtension.lowercased() == "app" {
            let path = child.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            let bundle = Bundle(url: child)
            let name =
              bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
              ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
              ?? child.deletingPathExtension().lastPathComponent
            applications.append(
              StartupItemApplication(
                name: name,
                bundleIdentifier: bundle?.bundleIdentifier ?? "",
                url: child.standardizedFileURL,
                teamIdentifier: StartupItemCodeSignature.teamIdentifier(at: child)
              )
            )
          } else if depth < maximumDepth {
            stack.append((child, depth + 1))
          }
        }
      }
    }
    return applications
  }

  private func serviceDomain(for kind: StartupItemKind) -> String {
    kind == .daemon ? "system" : "gui/\(userID)"
  }

  private func serviceTarget(for item: StartupItem) -> String {
    "\(serviceDomain(for: item.kind))/\(item.label)"
  }

  private func isAllowed(_ url: URL, kind: StartupItemKind) -> Bool {
    let expectedRoot: URL
    switch kind {
    case .userAgent:
      expectedRoot = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    case .globalAgent:
      expectedRoot = URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
    case .daemon:
      expectedRoot = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    }
    let path = url.standardizedFileURL.path
    let root = expectedRoot.standardizedFileURL.path
    return path.hasPrefix(root + "/") && url.pathExtension.lowercased() == "plist"
  }

  private func launchctlSucceeds(_ arguments: [String]) -> Bool {
    runLaunchctl(arguments, capturesOutput: false).status == 0
  }

  private func runLaunchctl(
    _ arguments: [String],
    capturesOutput: Bool
  ) -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = capturesOutput ? output : FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return (1, "")
    }
    let data = capturesOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  }

  private func administratorResult(
    _ result: AdministratorAuthorizationResult
  ) -> StartupItemOperationResult {
    switch result {
    case .success: .success
    case .cancelled: .cancelled
    case .failure(let message): .failure(message)
    }
  }

  private static func residueRank(_ state: StartupItemResidueState) -> Int {
    switch state {
    case .none: 0
    case .suspected: 1
    case .confirmed: 2
    }
  }
}

enum StartupItemParser {
  static func parse(
    data: Data,
    plistURL: URL,
    kind: StartupItemKind,
    applications: [StartupItemApplication],
    home: URL,
    fileExists: (URL) -> Bool,
    teamIdentifier: (URL) -> String? = { _ in nil }
  ) throws -> StartupItem {
    let propertyList = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    guard let dictionary = propertyList as? [String: Any] else {
      throw CocoaError(.propertyListReadCorrupt)
    }

    let declaredLabel = nonemptyString(dictionary["Label"])
    let fallbackLabel = plistURL.deletingPathExtension().lastPathComponent
    let label = declaredLabel ?? fallbackLabel
    let program = nonemptyString(dictionary["Program"])
    let arguments = dictionary["ProgramArguments"] as? [String] ?? []
    let bundleProgram = nonemptyString(dictionary["BundleProgram"])
    let openBundleIdentifier = bundleIdentifierForOpen(arguments: arguments, program: program)
    let executableURL = executableURL(
      program: program,
      arguments: arguments,
      bundleProgram: bundleProgram,
      home: home
    )
    let embeddedApplicationURL = executableURL.flatMap(applicationURL(in:))
    let directlyMatchedApplication = matchingApplication(
      label: label,
      requestedBundleIdentifier: openBundleIdentifier,
      embeddedApplicationURL: embeddedApplicationURL,
      applications: applications
    )

    let targetExists = executableURL.map(fileExists)
    let executableTeamIdentifier = executableURL.flatMap(teamIdentifier)
    let teamApplications = applications.filter {
      executableTeamIdentifier != nil && $0.teamIdentifier == executableTeamIdentifier
    }
    let application = directlyMatchedApplication
      ?? (teamApplications.count == 1 ? teamApplications[0] : nil)
    let hasInstalledApplicationFromTeam = !teamApplications.isEmpty
    let ownerKind: StartupItemOwnerKind
    let ownerName: String?
    let residueState: StartupItemResidueState
    if let application {
      ownerKind = .installedApplication
      ownerName = application.name
      residueState = .none
    } else if let executableURL, targetExists == true,
      isCommandLineTool(executableURL, home: home)
    {
      ownerKind = .commandLineTool
      ownerName = executableURL.lastPathComponent
      residueState = .none
    } else {
      ownerKind = .unknown
      ownerName = embeddedApplicationURL?.deletingPathExtension().lastPathComponent
      if targetExists == false {
        residueState = .confirmed
      } else if declaredLabel == nil || dictionary.isEmpty {
        residueState = .suspected
      } else if openBundleIdentifier != nil, directlyMatchedApplication == nil {
        residueState = .suspected
      } else if let executableURL, targetExists == true,
        isDetachedHelper(executableURL),
        executableTeamIdentifier != nil,
        !hasInstalledApplicationFromTeam
      {
        residueState = .suspected
      } else {
        residueState = .none
      }
    }

    let parseIssue: String?
    if declaredLabel == nil {
      parseIssue = "Missing launchd label"
    } else if executableURL == nil, openBundleIdentifier == nil {
      parseIssue = "Executable target unavailable"
    } else {
      parseIssue = nil
    }

    return StartupItem(
      id: plistURL.standardizedFileURL.path,
      label: label,
      name: ownerName ?? label,
      plistURL: plistURL.standardizedFileURL,
      executableURL: executableURL?.standardizedFileURL,
      requestedBundleIdentifier: openBundleIdentifier,
      executableTeamIdentifier: executableTeamIdentifier,
      ownerName: ownerName,
      ownerBundleIdentifier: application?.bundleIdentifier ?? openBundleIdentifier,
      ownerApplicationURL: application?.url,
      kind: kind,
      permissionState: declaredLabel == nil ? .unavailable : .allowed,
      runtimeState: declaredLabel == nil ? .unavailable : .unloaded,
      triggerMode: triggerMode(dictionary, kind: kind),
      residueState: residueState,
      ownerKind: ownerKind,
      hasValidLabel: declaredLabel != nil,
      runAtLoad: dictionary["RunAtLoad"] as? Bool ?? false,
      keepAlive: keepAlive(dictionary["KeepAlive"]),
      parseIssue: parseIssue
    )
  }

  private static func executableURL(
    program: String?,
    arguments: [String],
    bundleProgram: String?,
    home: URL
  ) -> URL? {
    let command = program ?? arguments.first
    let commandArguments = program == nil ? Array(arguments.dropFirst()) : arguments
    if command == "/usr/bin/open" {
      if let path = commandArguments.first(where: { !$0.hasPrefix("-") && isPath($0) }) {
        return expandedURL(path, home: home)
      }
      return nil
    }
    if command == "/usr/bin/env",
      let path = commandArguments.first(where: { isPath($0) })
    {
      return expandedURL(path, home: home)
    }
    if let command, isPath(command) {
      return expandedURL(command, home: home)
    }
    if let bundleProgram, isPath(bundleProgram) {
      return expandedURL(bundleProgram, home: home)
    }
    return nil
  }

  private static func matchingApplication(
    label: String,
    requestedBundleIdentifier: String?,
    embeddedApplicationURL: URL?,
    applications: [StartupItemApplication]
  ) -> StartupItemApplication? {
    if let embeddedApplicationURL {
      let path = embeddedApplicationURL.standardizedFileURL.path
      if let match = applications.first(where: { $0.url.standardizedFileURL.path == path }) {
        return match
      }
    }
    if let requestedBundleIdentifier,
      let match = applications.first(where: { $0.bundleIdentifier == requestedBundleIdentifier })
    {
      return match
    }
    return applications
      .filter {
        !$0.bundleIdentifier.isEmpty
          && (label == $0.bundleIdentifier || label.hasPrefix($0.bundleIdentifier + "."))
      }
      .max { $0.bundleIdentifier.count < $1.bundleIdentifier.count }
  }

  private static func bundleIdentifierForOpen(arguments: [String], program: String?) -> String? {
    let commandArguments = program == nil ? Array(arguments.dropFirst()) : arguments
    guard let index = commandArguments.firstIndex(of: "-b"),
      commandArguments.indices.contains(index + 1)
    else {
      return nil
    }
    return nonemptyString(commandArguments[index + 1])
  }

  private static func applicationURL(in executableURL: URL) -> URL? {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in executableURL.standardizedFileURL.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      if component.lowercased().hasSuffix(".app") {
        return current.standardizedFileURL
      }
    }
    return nil
  }

  private static func isCommandLineTool(_ url: URL, home: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let commandLineRoots = [
      "/opt/homebrew/",
      "/usr/local/",
      home.appendingPathComponent(".local", isDirectory: true).path + "/",
      home.appendingPathComponent(".nvm", isDirectory: true).path + "/",
      home.appendingPathComponent(".cargo", isDirectory: true).path + "/",
    ]
    return commandLineRoots.contains(where: path.hasPrefix)
  }

  private static func isDetachedHelper(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return path.hasPrefix("/Library/PrivilegedHelperTools/")
      || path.hasPrefix("/Library/Application Support/")
  }

  private static func isPath(_ value: String) -> Bool {
    value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("$HOME/")
  }

  private static func expandedURL(_ value: String, home: URL) -> URL {
    if value.hasPrefix("~/") {
      return home.appendingPathComponent(String(value.dropFirst(2)))
    }
    if value.hasPrefix("$HOME/") {
      return home.appendingPathComponent(String(value.dropFirst(6)))
    }
    return URL(fileURLWithPath: value)
  }

  private static func keepAlive(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? [String: Any] { return !value.isEmpty }
    return false
  }

  private static func triggerMode(
    _ dictionary: [String: Any],
    kind: StartupItemKind
  ) -> StartupItemTriggerMode {
    if keepAlive(dictionary["KeepAlive"]) { return .continuous }
    if dictionary["RunAtLoad"] as? Bool == true {
      return kind == .daemon ? .atBoot : .atLogin
    }
    if dictionary["StartInterval"] != nil || dictionary["StartCalendarInterval"] != nil {
      return .scheduled
    }
    let demandKeys = [
      "MachServices", "Sockets", "WatchPaths", "QueueDirectories",
      "StartOnMount", "OtherJobEnabled",
    ]
    if demandKeys.contains(where: { dictionary[$0] != nil }) { return .onDemand }
    return .manual
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return value
  }
}

enum StartupItemCodeSignature {
  static func teamIdentifier(at url: URL) -> String? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    var signingInformation: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    ) == errSecSuccess,
      let information = signingInformation as? [String: Any],
      let identifier = information[kSecCodeInfoTeamIdentifier as String] as? String
    else {
      return nil
    }
    let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

private extension StartupItem {
  func replacing(
    permissionState: StartupItemPermissionState,
    runtimeState: StartupItemRuntimeState
  ) -> StartupItem {
    StartupItem(
      id: id,
      label: label,
      name: name,
      plistURL: plistURL,
      executableURL: executableURL,
      requestedBundleIdentifier: requestedBundleIdentifier,
      executableTeamIdentifier: executableTeamIdentifier,
      ownerName: ownerName,
      ownerBundleIdentifier: ownerBundleIdentifier,
      ownerApplicationURL: ownerApplicationURL,
      kind: kind,
      permissionState: permissionState,
      runtimeState: runtimeState,
      triggerMode: triggerMode,
      residueState: residueState,
      ownerKind: ownerKind,
      hasValidLabel: hasValidLabel,
      runAtLoad: runAtLoad,
      keepAlive: keepAlive,
      parseIssue: parseIssue
    )
  }
}

private struct SystemLoginItemPayload: Decodable {
  let name: String
  let path: String?
  let hidden: Bool
}
