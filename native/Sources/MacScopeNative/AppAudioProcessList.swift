import AppKit
import CoreAudio
import Darwin
import Foundation

protocol AppAudioProcessListing: AnyObject {
  func outputProcesses() -> [AudioProcessSnapshot]
}

final class CoreAudioAppProcessList: AppAudioProcessListing, @unchecked Sendable {
  func outputProcesses() -> [AudioProcessSnapshot] {
    CoreAudioProperty.objectIDs(kAudioHardwarePropertyProcessObjectList).compactMap { objectID in
      guard let pid: pid_t = CoreAudioProperty.value(kAudioProcessPropertyPID, objectID: objectID),
        pid > 0
      else { return nil }
      let running: UInt32? = CoreAudioProperty.value(
        kAudioProcessPropertyIsRunningOutput,
        objectID: objectID
      )
      guard running == 1 else { return nil }
      let bundleID = CoreAudioProperty.string(kAudioProcessPropertyBundleID, objectID: objectID)
      return AudioProcessSnapshot(
        objectID: objectID,
        pid: pid,
        bundleID: bundleID,
        executablePath: Self.executablePath(pid: pid)
      )
    }
  }

  private static func executablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let path = String(decoding: bytes, as: UTF8.self)
    return path.isEmpty ? nil : path
  }
}

enum AppAudioProcessName {
  static func resolve(_ process: AudioProcessSnapshot) -> (name: String, bundlePath: String?) {
    if let appPath = AppAudioOwningApp.resolvedApplicationPath(
      executablePath: process.executablePath,
      bundleID: process.bundleID
    ) {
      let name = applicationDisplayName(appPath: appPath)
      if !name.isEmpty {
        return (name, appPath)
      }
    }
    let running = NSRunningApplication(processIdentifier: process.pid)
    if let name = running?.localizedName, !name.isEmpty {
      return (displayName(name), running?.bundleURL?.path)
    }
    if let bundleID = process.bundleID, !bundleID.isEmpty {
      return (displayName(bundleID), running?.bundleURL?.path)
    }
    return (displayName(executableName(pid: process.pid) ?? "PID \(process.pid)"), running?.bundleURL?.path)
  }

  private static func applicationDisplayName(appPath: String) -> String {
    if let bundle = Bundle(url: URL(fileURLWithPath: appPath)) {
      let localized = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
      let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
      if let name = localized ?? display ?? bundleName, !name.isEmpty {
        return displayName(name)
      }
    }
    return displayName(FileManager.default.displayName(atPath: appPath))
  }

  static func displayName(_ name: String) -> String {
    name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  private static func executableName(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let name = String(decoding: bytes, as: UTF8.self)
    return name.isEmpty ? nil : name
  }
}
