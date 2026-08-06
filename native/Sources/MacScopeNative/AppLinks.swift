import AppKit
import Foundation

enum AppLinks {
  static let author = URL(string: "https://github.com/shenmuoso")!
  static let github = URL(string: "https://github.com/shenmuoso/mac-scope")!
  static let newIssue = URL(string: "https://github.com/shenmuoso/mac-scope/issues/new")!

  @MainActor
  static func openGitHub() {
    NSWorkspace.shared.open(github)
  }

  @MainActor
  static func openNewIssue() {
    NSWorkspace.shared.open(newIssue)
  }
}

enum AppMetadata {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.11"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "15"
  }
}
