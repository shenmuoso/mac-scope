import AppKit
import Combine
import Foundation

struct AvailableUpdate: Equatable, Identifiable, Sendable {
  let version: String
  let releaseURL: URL
  let downloadURL: URL

  var id: String { version }
}

enum UpdateCheckState: Equatable, Sendable {
  case idle
  case checking
  case upToDate
  case available(AvailableUpdate)
}

struct GitHubRelease: Decodable, Sendable {
  struct Asset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let state: String

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
      case state
    }
  }

  let tagName: String
  let name: String?
  let htmlURL: URL
  let draft: Bool
  let prerelease: Bool
  let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case name
    case htmlURL = "html_url"
    case draft
    case prerelease
    case assets
  }
}

struct SemanticVersion: Comparable, Sendable {
  let components: [Int]
  let displayString: String

  init?(extracting value: String) {
    let pattern = #"(?<![0-9])([0-9]+(?:\.[0-9]+){1,3})(?![0-9])"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      let versionRange = Range(match.range(at: 1), in: value)
    else {
      return nil
    }

    let candidate = String(value[versionRange])
    let parsedComponents = candidate.split(separator: ".").compactMap { Int($0) }
    guard parsedComponents.count >= 2 else { return nil }
    components = parsedComponents
    displayString = candidate
  }

  static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    compare(lhs.components, rhs.components) == 0
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    compare(lhs.components, rhs.components) < 0
  }

  private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left < right ? -1 : 1 }
    }
    return 0
  }
}

enum UpdateArchitecture: Sendable {
  case arm64
  case x86
  case unknown

  static var current: UpdateArchitecture {
    #if arch(arm64)
      .arm64
    #elseif arch(x86_64)
      .x86
    #else
      .unknown
    #endif
  }

  var assetTokens: [String] {
    switch self {
    case .arm64: ["arm64", "apple-silicon", "apple_silicon"]
    case .x86: ["x86_64", "x64", "amd64", "intel"]
    case .unknown: []
    }
  }
}

struct UpdateReleaseResolution: Equatable, Sendable {
  let latestVersion: String
  let releaseURL: URL
  let downloadURL: URL
  let isUpdateAvailable: Bool
}

enum UpdateReleaseResolver {
  static func resolve(
    release: GitHubRelease,
    currentVersion: String,
    architecture: UpdateArchitecture = .current
  ) -> UpdateReleaseResolution? {
    guard !release.draft, !release.prerelease,
      let localVersion = SemanticVersion(extracting: currentVersion),
      let remoteVersion = SemanticVersion(extracting: release.tagName)
        ?? release.name.flatMap({ SemanticVersion(extracting: $0) }),
      let releaseURL = trustedGitHubURL(release.htmlURL)
    else {
      return nil
    }

    let downloadURL =
      preferredDMGURL(
        from: release.assets,
        architecture: architecture
      ) ?? releaseURL
    return UpdateReleaseResolution(
      latestVersion: remoteVersion.displayString,
      releaseURL: releaseURL,
      downloadURL: downloadURL,
      isUpdateAvailable: remoteVersion > localVersion
    )
  }

  static func trustedGitHubURL(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com"
    else {
      return nil
    }
    return url
  }

  private static func preferredDMGURL(
    from assets: [GitHubRelease.Asset],
    architecture: UpdateArchitecture
  ) -> URL? {
    let diskImages = assets.filter { asset in
      asset.state == "uploaded"
        && asset.name.lowercased().hasSuffix(".dmg")
        && trustedGitHubURL(asset.browserDownloadURL) != nil
    }
    guard !diskImages.isEmpty else { return nil }

    if let architectureMatch = diskImages.first(where: { asset in
      let name = asset.name.lowercased()
      return architecture.assetTokens.contains { name.contains($0) }
    }) {
      return architectureMatch.browserDownloadURL
    }
    if let universal = diskImages.first(where: {
      $0.name.lowercased().contains("universal")
    }) {
      return universal.browserDownloadURL
    }
    return diskImages.first?.browserDownloadURL
  }
}

@MainActor
final class UpdateChecker: ObservableObject {
  private enum Key {
    static let lastSuccessfulCheck = "native.update.lastSuccessfulCheck"
    static let latestVersion = "native.update.latestVersion"
    static let releaseURL = "native.update.releaseURL"
    static let downloadURL = "native.update.downloadURL"
  }

  private enum CheckError: Error {
    case invalidResponse
    case invalidRelease
  }

  @Published private(set) var state = UpdateCheckState.idle

  var availableUpdate: AvailableUpdate? {
    guard case .available(let update) = state else { return nil }
    return update
  }

  private let defaults: UserDefaults
  private let currentVersion: String
  private var checkTask: Task<Void, Never>?
  private var lastAttemptAt: Date?
  private var hasCachedResult = false

  init(
    defaults: UserDefaults = .standard,
    currentVersion: String = AppMetadata.version
  ) {
    self.defaults = defaults
    self.currentVersion = currentVersion
    restoreCachedResult()
  }

  func checkIfNeeded(force: Bool = false) {
    guard checkTask == nil else { return }
    let now = Date()

    if !force {
      if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < 3_600 {
        return
      }
      if hasCachedResult,
        let lastCheck = defaults.object(forKey: Key.lastSuccessfulCheck) as? Date,
        now.timeIntervalSince(lastCheck) < 86_400
      {
        return
      }
    }

    lastAttemptAt = now
    let fallbackState = state
    if availableUpdate == nil {
      state = .checking
    }

    checkTask = Task { [weak self] in
      guard let self else { return }
      do {
        let release = try await Self.fetchLatestRelease()
        guard
          let resolution = UpdateReleaseResolver.resolve(
            release: release,
            currentVersion: self.currentVersion
          )
        else {
          throw CheckError.invalidRelease
        }
        self.apply(resolution, checkedAt: Date())
      } catch is CancellationError {
        self.state = fallbackState
      } catch {
        self.state = fallbackState == .checking ? .idle : fallbackState
      }
      self.checkTask = nil
    }
  }

  func downloadAvailableUpdate() {
    guard let availableUpdate else { return }
    NSWorkspace.shared.open(availableUpdate.downloadURL)
  }

  private func apply(_ resolution: UpdateReleaseResolution, checkedAt: Date) {
    defaults.set(checkedAt, forKey: Key.lastSuccessfulCheck)
    defaults.set(resolution.latestVersion, forKey: Key.latestVersion)
    defaults.set(resolution.releaseURL.absoluteString, forKey: Key.releaseURL)
    defaults.set(resolution.downloadURL.absoluteString, forKey: Key.downloadURL)
    hasCachedResult = true

    if resolution.isUpdateAvailable {
      state = .available(
        AvailableUpdate(
          version: resolution.latestVersion,
          releaseURL: resolution.releaseURL,
          downloadURL: resolution.downloadURL
        )
      )
    } else {
      state = .upToDate
    }
  }

  private func restoreCachedResult() {
    guard let latestVersion = defaults.string(forKey: Key.latestVersion),
      let remoteVersion = SemanticVersion(extracting: latestVersion),
      let localVersion = SemanticVersion(extracting: currentVersion),
      let releaseValue = defaults.string(forKey: Key.releaseURL),
      let releaseURL = URL(string: releaseValue).flatMap(UpdateReleaseResolver.trustedGitHubURL),
      let downloadValue = defaults.string(forKey: Key.downloadURL),
      let downloadURL = URL(string: downloadValue).flatMap(UpdateReleaseResolver.trustedGitHubURL)
    else {
      return
    }

    hasCachedResult = true
    if remoteVersion > localVersion {
      state = .available(
        AvailableUpdate(
          version: remoteVersion.displayString,
          releaseURL: releaseURL,
          downloadURL: downloadURL
        )
      )
    } else {
      state = .upToDate
    }
  }

  private static func fetchLatestRelease() async throws -> GitHubRelease {
    guard
      let url = URL(
        string: "https://api.github.com/repos/shenmuoso/mac-scope/releases/latest"
      )
    else {
      throw CheckError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("MacScope/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw CheckError.invalidResponse
    }
    return try JSONDecoder().decode(GitHubRelease.self, from: data)
  }
}
