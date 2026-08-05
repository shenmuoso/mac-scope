import AppKit
import Foundation

enum AdministratorAuthorizationResult: Sendable {
  case success
  case cancelled
  case failure(String)
}

struct AdministratorTrashItem: Sendable {
  let source: URL
  let serviceTarget: String?
}

enum SystemPermission {
  @MainActor
  static func openFilesAndFoldersSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor
  static func openFullDiskAccessSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor
  static func openAutomationSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  static func moveToTrashWithAdministratorAuthorization(
    _ source: URL
  ) -> AdministratorAuthorizationResult {
    let fileManager = FileManager.default
    let trash = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      ".Trash",
      isDirectory: true
    )
    var destination = trash.appendingPathComponent(source.lastPathComponent)
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      let stem = source.deletingPathExtension().lastPathComponent
      let extensionName = source.pathExtension
      let candidate =
        extensionName.isEmpty
        ? "\(stem) \(suffix)"
        : "\(stem) \(suffix).\(extensionName)"
      destination = trash.appendingPathComponent(candidate)
      suffix += 1
    }

    let script = [
      "on run argv",
      "do shell script \"/bin/mv \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv with administrator privileges",
      "end run",
    ]
    let result = runAppleScript(script, arguments: [source.path, destination.path])
    return authorizationResult(for: result)
  }

  static func purgeFileCacheWithAdministratorAuthorization() -> AdministratorAuthorizationResult {
    let script = [
      "do shell script \"/usr/bin/purge\" with administrator privileges"
    ]
    let result = runAppleScript(script, arguments: [])
    return authorizationResult(for: result)
  }

  static func setStartupItemEnabledWithAdministratorAuthorization(
    _ isEnabled: Bool,
    serviceTarget: String,
    domain: String,
    plistURL: URL
  ) -> AdministratorAuthorizationResult {
    let script: [String]
    if isEnabled {
      script = [
        "on run argv",
        "set serviceTarget to item 1 of argv",
        "set serviceDomain to item 2 of argv",
        "set plistPath to item 3 of argv",
        "set commandText to \"/bin/launchctl enable \" & quoted form of serviceTarget & \"; if ! /bin/launchctl print \" & quoted form of serviceTarget & \" >/dev/null 2>&1; then /bin/launchctl bootstrap \" & quoted form of serviceDomain & \" \" & quoted form of plistPath & \"; fi\"",
        "do shell script commandText with administrator privileges",
        "end run",
      ]
    } else {
      script = [
        "on run argv",
        "set serviceTarget to item 1 of argv",
        "set commandText to \"/bin/launchctl disable \" & quoted form of serviceTarget & \"; /bin/launchctl bootout \" & quoted form of serviceTarget & \" >/dev/null 2>&1 || true\"",
        "do shell script commandText with administrator privileges",
        "end run",
      ]
    }
    let arguments = isEnabled
      ? [serviceTarget, domain, plistURL.path]
      : [serviceTarget]
    return authorizationResult(for: runAppleScript(script, arguments: arguments))
  }

  static func removeStartupItemWithAdministratorAuthorization(
    serviceTarget: String,
    plistURL: URL
  ) -> AdministratorAuthorizationResult {
    let destination = availableTrashDestination(for: plistURL)
    let script = [
      "on run argv",
      "set serviceTarget to item 1 of argv",
      "set sourcePath to item 2 of argv",
      "set destinationPath to item 3 of argv",
      "set commandText to \"\"",
      "if serviceTarget is not \"\" then set commandText to commandText & \"/bin/launchctl bootout \" & quoted form of serviceTarget & \" >/dev/null 2>&1 || true; /bin/launchctl enable \" & quoted form of serviceTarget & \" >/dev/null 2>&1 || true; \"",
      "set commandText to commandText & \"/bin/mv \" & quoted form of sourcePath & \" \" & quoted form of destinationPath",
      "do shell script commandText with administrator privileges",
      "end run",
    ]
    return authorizationResult(
      for: runAppleScript(
        script,
        arguments: [serviceTarget, plistURL.path, destination.path]
      )
    )
  }

  static func moveItemsToTrashWithAdministratorAuthorization(
    _ items: [AdministratorTrashItem]
  ) -> AdministratorAuthorizationResult {
    guard !items.isEmpty else { return .success }
    var reservedDestinations = Set<String>()
    let arguments = items.flatMap { item -> [String] in
      let destination = availableTrashDestination(
        for: item.source,
        reserving: &reservedDestinations
      )
      return [item.serviceTarget ?? "", item.source.path, destination.path]
    }
    let script = [
      "on run argv",
      "set commandText to \"set -e; \"",
      "repeat with itemIndex from 1 to (count argv) by 3",
      "set serviceTarget to item itemIndex of argv",
      "set sourcePath to item (itemIndex + 1) of argv",
      "set destinationPath to item (itemIndex + 2) of argv",
      "if serviceTarget is not \"\" then set commandText to commandText & \"/bin/launchctl bootout \" & quoted form of serviceTarget & \" >/dev/null 2>&1 || true; /bin/launchctl enable \" & quoted form of serviceTarget & \" >/dev/null 2>&1 || true; \"",
      "set commandText to commandText & \"/bin/mv \" & quoted form of sourcePath & \" \" & quoted form of destinationPath & \"; \"",
      "end repeat",
      "do shell script commandText with administrator privileges",
      "end run",
    ]
    return authorizationResult(for: runAppleScript(script, arguments: arguments))
  }

  static func unregisterApplication(at url: URL) {
    let executable = URL(
      fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-u", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  private static func availableTrashDestination(for source: URL) -> URL {
    var reserved = Set<String>()
    return availableTrashDestination(for: source, reserving: &reserved)
  }

  private static func availableTrashDestination(
    for source: URL,
    reserving reserved: inout Set<String>
  ) -> URL {
    let fileManager = FileManager.default
    let trash = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      ".Trash",
      isDirectory: true
    )
    var destination = trash.appendingPathComponent(source.lastPathComponent)
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path)
      || reserved.contains(destination.standardizedFileURL.path)
    {
      let stem = source.deletingPathExtension().lastPathComponent
      let extensionName = source.pathExtension
      let candidate = extensionName.isEmpty
        ? "\(stem) \(suffix)"
        : "\(stem) \(suffix).\(extensionName)"
      destination = trash.appendingPathComponent(candidate)
      suffix += 1
    }
    reserved.insert(destination.standardizedFileURL.path)
    return destination
  }

  private static func runAppleScript(
    _ statements: [String],
    arguments: [String]
  ) -> (status: Int32, message: String) {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = statements.flatMap { ["-e", $0] } + arguments
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
    let message =
      String(data: messageData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, message)
  }

  private static func authorizationResult(
    for result: (status: Int32, message: String)
  ) -> AdministratorAuthorizationResult {
    guard result.status != 0 else { return .success }
    let normalizedMessage = result.message.lowercased()
    if normalizedMessage.contains("(-128)")
      || normalizedMessage.contains("user canceled")
      || normalizedMessage.contains("user cancelled")
    {
      return .cancelled
    }
    return .failure(
      result.message.isEmpty ? "The authorized operation did not complete." : result.message
    )
  }
}
