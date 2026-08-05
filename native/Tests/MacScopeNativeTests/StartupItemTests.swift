import Foundation
import Testing

@testable import MacScopeNative

@Suite("Startup items")
struct StartupItemTests {
  @Test("Missing application targets are confirmed remnants")
  func missingApplicationTarget() throws {
    let item = try parse(
      [
        "Label": "com.example.removed.helper",
        "ProgramArguments": [
          "/usr/bin/open", "-gj", "/Applications/Removed.app",
        ],
      ],
      fileExists: { _ in false }
    )

    #expect(item.executableURL?.path == "/Applications/Removed.app")
    #expect(item.ownerName == "Removed")
    #expect(item.residueState == .confirmed)
  }

  @Test("Installed applications own matching helper labels")
  func installedApplicationOwnsHelper() throws {
    let application = StartupItemApplication(
      name: "Example",
      bundleIdentifier: "com.example.Example",
      url: URL(fileURLWithPath: "/Applications/Example.app")
    )
    let item = try parse(
      [
        "Label": "com.example.Example.helper",
        "Program": "/Library/PrivilegedHelperTools/com.example.helper",
      ],
      applications: [application],
      fileExists: { _ in true }
    )

    #expect(item.ownerName == "Example")
    #expect(item.ownerBundleIdentifier == "com.example.Example")
    #expect(item.ownerKind == .installedApplication)
    #expect(item.residueState == .none)
  }

  @Test("Existing Homebrew services are command-line tools")
  func homebrewService() throws {
    let item = try parse(
      [
        "Label": "homebrew.mxcl.redis",
        "ProgramArguments": ["/opt/homebrew/opt/redis/bin/redis-server"],
      ],
      fileExists: { _ in true }
    )

    #expect(item.ownerKind == .commandLineTool)
    #expect(item.residueState == .none)
  }

  @Test("Signed helpers are associated with an installed application from the same team")
  func helperOwnedBySigningTeam() throws {
    let helperURL = URL(
      fileURLWithPath: "/Library/PrivilegedHelperTools/com.example.helper"
    )
    let application = StartupItemApplication(
      name: "Example",
      bundleIdentifier: "com.example.application",
      url: URL(fileURLWithPath: "/Applications/Example.app"),
      teamIdentifier: "EXAMPLETEAM"
    )
    let item = try parse(
      [
        "Label": "com.vendor.detached-helper",
        "Program": helperURL.path,
      ],
      applications: [application],
      fileExists: { _ in true },
      teamIdentifier: { $0 == helperURL ? "EXAMPLETEAM" : nil }
    )

    #expect(item.ownerName == "Example")
    #expect(item.ownerApplicationURL == application.url)
    #expect(item.residueState == .none)
  }

  @Test("Unsigned existing helpers remain unknown instead of being reported as remnants")
  func unsignedDetachedHelper() throws {
    let item = try parse(
      [
        "Label": "com.example.unsigned-helper",
        "Program": "/Library/PrivilegedHelperTools/com.example.unsigned-helper",
      ],
      fileExists: { _ in true }
    )

    #expect(item.ownerKind == .unknown)
    #expect(item.residueState == .none)
  }

  @Test("Signed helpers without an installed application from their team are possible remnants")
  func orphanedSignedHelper() throws {
    let item = try parse(
      [
        "Label": "com.example.orphaned-helper",
        "Program": "/Library/PrivilegedHelperTools/com.example.orphaned-helper",
      ],
      fileExists: { _ in true },
      teamIdentifier: { _ in "REMOVEDTEAM" }
    )

    #expect(item.ownerKind == .unknown)
    #expect(item.residueState == .suspected)
  }

  @Test("Missing bundle identifier targets are possible remnants")
  func missingBundleIdentifierTarget() throws {
    let item = try parse(
      [
        "Label": "com.example.removed.login-item",
        "ProgramArguments": [
          "/usr/bin/open", "-gj", "-b", "com.example.removed",
        ],
      ],
      fileExists: { _ in true }
    )

    #expect(item.executableURL == nil)
    #expect(item.ownerBundleIdentifier == "com.example.removed")
    #expect(item.residueState == .suspected)
  }

  @Test("Malformed launchd placeholders are possible remnants")
  func malformedPlaceholder() throws {
    let item = try parse([:], fileExists: { _ in false })

    #expect(!item.hasValidLabel)
    #expect(item.permissionState == .unavailable)
    #expect(item.residueState == .suspected)
  }

  @Test("Disabled launchctl overrides are parsed by label")
  func disabledOverrides() {
    let output = """
      disabled services = {
        "com.example.disabled" => disabled
        "com.example.enabled" => enabled
      }
      """
    let values = StartupItemService.parseDisabledServices(output)

    #expect(values["com.example.disabled"] == true)
    #expect(values["com.example.enabled"] == false)
  }

  @Test("launchctl output separates running jobs from loaded waiting jobs")
  func launchctlRuntimeState() {
    let running = StartupItemService.runtimeState(
      launchctlStatus: 0,
      output: """
        com.example.worker = {
          state = running
          pid = 4242
        }
        """,
      permissionState: .allowed
    )
    let waiting = StartupItemService.runtimeState(
      launchctlStatus: 0,
      output: "state = waiting",
      permissionState: .allowed
    )
    let unloaded = StartupItemService.runtimeState(
      launchctlStatus: 113,
      output: "",
      permissionState: .allowed
    )

    #expect(running == .running(pid: 4242))
    #expect(waiting == .waiting)
    #expect(unloaded == .unloaded)
  }

  @Test("launchd trigger keys produce user-facing startup modes")
  func launchdTriggerModes() throws {
    let continuous = try parse(
      ["Label": "continuous", "Program": "/usr/bin/true", "KeepAlive": true],
      fileExists: { _ in true }
    )
    let scheduled = try parse(
      ["Label": "scheduled", "Program": "/usr/bin/true", "StartInterval": 60],
      fileExists: { _ in true }
    )
    let boot = try parse(
      ["Label": "boot", "Program": "/usr/bin/true", "RunAtLoad": true],
      kind: .daemon,
      fileExists: { _ in true }
    )

    #expect(continuous.triggerMode == .continuous)
    #expect(scheduled.triggerMode == .scheduled)
    #expect(boot.triggerMode == .atBoot)
  }

  @Test("Login item paths distinguish installed apps from confirmed remnants")
  func loginItemPathResidue() throws {
    let applications = [
      StartupItemApplication(
        name: "Example",
        bundleIdentifier: "com.example.app",
        url: URL(fileURLWithPath: "/Applications/Example.app")
      )
    ]
    let output = """
      [
        {"name":"Example","path":"/Applications/Example.app","hidden":false},
        {"name":"Removed","path":"/Applications/Removed.app","hidden":false}
      ]
      """
    let items = try StartupItemService.parseLoginItemsJSON(
      output,
      applications: applications,
      fileExists: { $0.path == "/Applications/Example.app" }
    )

    #expect(items.first(where: { $0.name == "Example" })?.residueState == .some(.none))
    #expect(items.first(where: { $0.name == "Removed" })?.residueState == .confirmed)
  }

  @Test("Unresolved Login Items require review unless a standard installation matches")
  func unresolvedLoginItems() throws {
    let applications = [
      StartupItemApplication(
        name: "Installed",
        bundleIdentifier: "com.example.installed",
        url: URL(fileURLWithPath: "/Applications/Installed.app")
      )
    ]
    let output = """
      [
        {"name":"Installed","path":null,"hidden":false},
        {"name":"Removed","path":null,"hidden":false}
      ]
      """
    let items = try StartupItemService.parseLoginItemsJSON(
      output,
      applications: applications,
      fileExists: { _ in false }
    )

    #expect(items.first(where: { $0.name == "Installed" })?.residueState == .some(.none))
    #expect(items.first(where: { $0.name == "Removed" })?.residueState == .suspected)
  }

  private func parse(
    _ dictionary: [String: Any],
    applications: [StartupItemApplication] = [],
    kind: StartupItemKind = .userAgent,
    fileExists: (URL) -> Bool,
    teamIdentifier: (URL) -> String? = { _ in nil }
  ) throws -> StartupItem {
    let data = try PropertyListSerialization.data(
      fromPropertyList: dictionary,
      format: .xml,
      options: 0
    )
    return try StartupItemParser.parse(
      data: data,
      plistURL: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/example.plist"),
      kind: kind,
      applications: applications,
      home: URL(fileURLWithPath: "/Users/test", isDirectory: true),
      fileExists: fileExists,
      teamIdentifier: teamIdentifier
    )
  }
}
