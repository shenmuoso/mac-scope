import Foundation
import Testing

@testable import MacScopeNative

@Suite("Update checking")
struct UpdateCheckerTests {
  @Test("Prefixed release tags use numeric version ordering")
  func comparesReleaseVersions() throws {
    let current = try #require(SemanticVersion(extracting: "0.4.9"))
    let latest = try #require(SemanticVersion(extracting: "preview-v0.4.10"))
    let equivalent = try #require(SemanticVersion(extracting: "v0.4.10.0"))

    #expect(latest > current)
    #expect(latest == equivalent)
  }

  @Test("The current architecture DMG is preferred")
  func selectsArchitectureAsset() throws {
    let releasePage = try #require(URL(string: "https://github.com/shenmuoso/mac-scope/releases/1"))
    let universal = try #require(
      URL(
        string: "https://github.com/shenmuoso/mac-scope/releases/download/1/MacScope-universal.dmg")
    )
    let arm64 = try #require(
      URL(string: "https://github.com/shenmuoso/mac-scope/releases/download/1/MacScope-arm64.dmg")
    )
    let release = GitHubRelease(
      tagName: "preview-v0.4.11",
      name: "MacScope 0.4.11",
      htmlURL: releasePage,
      draft: false,
      prerelease: false,
      assets: [
        GitHubRelease.Asset(
          name: "MacScope-universal.dmg", browserDownloadURL: universal, state: "uploaded"),
        GitHubRelease.Asset(
          name: "MacScope-arm64.dmg", browserDownloadURL: arm64, state: "uploaded"),
      ]
    )

    let resolution = try #require(
      UpdateReleaseResolver.resolve(
        release: release,
        currentVersion: "0.4.10",
        architecture: .arm64
      )
    )

    #expect(resolution.latestVersion == "0.4.11")
    #expect(resolution.isUpdateAvailable)
    #expect(resolution.downloadURL == arm64)
  }

  @Test("A release without a DMG opens its GitHub page")
  func fallsBackToReleasePage() throws {
    let releasePage = try #require(URL(string: "https://github.com/shenmuoso/mac-scope/releases/2"))
    let release = GitHubRelease(
      tagName: "v0.5.0",
      name: "MacScope 0.5.0",
      htmlURL: releasePage,
      draft: false,
      prerelease: false,
      assets: []
    )

    let resolution = try #require(
      UpdateReleaseResolver.resolve(release: release, currentVersion: "0.4.10")
    )

    #expect(resolution.downloadURL == releasePage)
  }

  @Test("Drafts, prereleases, and untrusted links are rejected")
  func rejectsUnavailableReleases() throws {
    let githubURL = try #require(URL(string: "https://github.com/shenmuoso/mac-scope/releases/3"))
    let untrustedURL = try #require(URL(string: "https://example.com/releases/3"))
    let draft = release(htmlURL: githubURL, draft: true)
    let prerelease = release(htmlURL: githubURL, prerelease: true)
    let untrusted = release(htmlURL: untrustedURL)

    #expect(UpdateReleaseResolver.resolve(release: draft, currentVersion: "0.4.10") == nil)
    #expect(UpdateReleaseResolver.resolve(release: prerelease, currentVersion: "0.4.10") == nil)
    #expect(UpdateReleaseResolver.resolve(release: untrusted, currentVersion: "0.4.10") == nil)
  }

  @Test("A cached newer release is restored without a network request")
  @MainActor
  func restoresCachedUpdate() throws {
    let suiteName = "UpdateCheckerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("0.4.11", forKey: "native.update.latestVersion")
    defaults.set(
      "https://github.com/shenmuoso/mac-scope/releases/4",
      forKey: "native.update.releaseURL"
    )
    defaults.set(
      "https://github.com/shenmuoso/mac-scope/releases/download/4/MacScope-arm64.dmg",
      forKey: "native.update.downloadURL"
    )
    defaults.set(Date(), forKey: "native.update.lastSuccessfulCheck")

    let checker = UpdateChecker(defaults: defaults, currentVersion: "0.4.10")
    let update = try #require(checker.availableUpdate)

    #expect(update.version == "0.4.11")
  }

  private func release(
    htmlURL: URL,
    draft: Bool = false,
    prerelease: Bool = false
  ) -> GitHubRelease {
    GitHubRelease(
      tagName: "v0.4.11",
      name: "MacScope 0.4.11",
      htmlURL: htmlURL,
      draft: draft,
      prerelease: prerelease,
      assets: []
    )
  }
}
