@preconcurrency import ColorSync
import CoreGraphics
import Foundation

struct DisplayColorProfile: Identifiable, Hashable, Sendable {
  let url: URL
  let name: String
  var id: String { url.path }
}

struct DisplayColorConfiguration: Sendable {
  let profiles: [DisplayColorProfile]
  let selectedID: String
  let factoryName: String
  let factoryURL: URL?
  let isAvailable: Bool
}

enum DisplayControlError: String, Error, LocalizedError {
  case disconnected = "The display has disconnected or changed. Refresh and try again."
  case brightnessUnavailable = "Hardware brightness control is unavailable for this display."
  case brightnessFailed = "The display did not confirm the new brightness."
  case profileUnavailable = "ColorSync profiles are unavailable for this display."
  case invalidProfile = "The selected RGB display profile is no longer available."
  case profileFailed = "macOS did not confirm the color profile change."
  case ddcUnavailable = "No unambiguous DDC connection was found for this display."
  case ddcNoReply = "No valid DDC reply. Check the monitor's DDC/CI setting and cable, then retry."
  case ddcWriteFailed = "The monitor did not confirm the DDC change."

  var errorDescription: String? { rawValue }
}

enum DisplayColorProfiles {
  static let factoryID = "factory"

  static func identity(_ displayID: UInt32) -> String? {
    guard CGDisplayIsOnline(displayID) != 0,
      let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
  }

  static func validate(_ displayID: UInt32, identity: String) throws {
    guard self.identity(displayID) == identity else { throw DisplayControlError.disconnected }
  }

  static func read(_ displayID: UInt32) -> DisplayColorConfiguration {
    guard let info = deviceInfo(displayID),
      let factory = info[key(kColorSyncFactoryProfiles)] as? [String: Any],
      let defaultID = factory[key(kColorSyncDeviceDefaultProfileID)] as? String,
      let record = factory[defaultID] as? [String: Any]
    else {
      return .init(profiles: [], selectedID: factoryID, factoryName: "Default", factoryURL: nil, isAvailable: false)
    }
    let factoryURL = record[key(kColorSyncDeviceProfileURL)] as? URL
    let custom = info[key(kColorSyncCustomProfiles)] as? [String: Any]
    let customURL = custom?[defaultID] as? URL
    let roots = [
      URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
      URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles"),
    ]
    var urls = Set([factoryURL, customURL].compactMap { $0 })
    for root in roots {
      guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
      ) else { continue }
      for case let url as URL in enumerator where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
        urls.insert(url)
      }
    }
    var profiles = urls.compactMap(profile).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    // Preserve a current profile even if it is outside the normal repositories.
    if let customURL, !profiles.contains(where: { $0.url == customURL }) {
      profiles.append(.init(url: customURL, name: customURL.deletingPathExtension().lastPathComponent))
    }
    return .init(
      profiles: profiles, selectedID: customURL?.path ?? factoryID,
      factoryName: factoryURL.flatMap(profile)?.name ?? "Default", factoryURL: factoryURL, isAvailable: true
    )
  }

  static func apply(_ id: String, displayID: UInt32, identity: String) throws {
    try validate(displayID, identity: identity)
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
      deviceInfo(displayID) != nil else { throw DisplayControlError.profileUnavailable }
    let url = URL(fileURLWithPath: id)
    if id != factoryID, profile(url) == nil { throw DisplayControlError.invalidProfile }
    let profiles: [String: Any] = [
      key(kColorSyncDeviceDefaultProfileID): id == factoryID ? kCFNull as Any : url as CFURL,
      key(kColorSyncProfileUserScope): kCFPreferencesCurrentUser as Any,
      key(kColorSyncProfileHostScope): kCFPreferencesCurrentHost as Any,
    ]
    guard ColorSyncDeviceSetCustomProfiles(
      kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, profiles as CFDictionary
    ) else { throw DisplayControlError.profileFailed }
    // ColorSync removes a redundant override when it points to the factory ICC.
    // Its result is semantically correct even though the selected ID is factory.
    for _ in 0..<4 {
      let actual = read(displayID)
      if actual.selectedID == id || (actual.selectedID == factoryID && actual.factoryURL?.path == id) {
        return
      }
      usleep(50000)
    }
    throw DisplayControlError.profileFailed
  }

  private static func profile(_ url: URL) -> DisplayColorProfile? {
    guard let data = try? Data(contentsOf: url), data.count >= 128,
      String(data: data[16..<20], encoding: .ascii) == "RGB ",
      ["mntr", "spac"].contains(String(data: data[12..<16], encoding: .ascii) ?? ""),
      let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue()
    else { return nil }
    let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    return .init(url: url, name: name ?? url.deletingPathExtension().lastPathComponent)
  }

  private static func deviceInfo(_ id: UInt32) -> [String: Any]? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return ColorSyncDeviceCopyDeviceInfo(
      kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid
    )?.takeRetainedValue() as? [String: Any]
  }

  private static func key(_ value: Unmanaged<CFString>!) -> String {
    value.takeUnretainedValue() as String
  }
}
