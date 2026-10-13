import CoreGraphics
import Darwin
import Foundation
import IOKit

// Optional entry points are resolved at runtime; the app still works when an OS
// version omits them. Keep undocumented APIs out of views and public API paths.
final class DisplaySystemInterfaces {
  typealias ModeQuery = @convention(c) (UInt32, Int32) -> Bool
  typealias LegacyModes = @convention(c) (UInt32) -> Unmanaged<CFArray>?
  typealias DisplayInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
  typealias ModeCount = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Int32
  typealias ModeDescription = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Int32
  typealias ConfigureMode = @convention(c) (CGDisplayConfigRef, UInt32, Int32) -> Int32
  typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
  typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
  typealias CreateAVService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  typealias AVTransfer = @convention(c) (
    CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
  ) -> IOReturn

  private var handles: [UnsafeMutableRawPointer] = []
  private(set) var isProMotion: ModeQuery?
  private(set) var isVariableRefresh: ModeQuery?
  private(set) var legacyModes: LegacyModes?
  private(set) var displayInfo: DisplayInfo?
  private var modeCount: ModeCount?
  private var currentModeIndex: ModeCount?
  private var modeDescription: ModeDescription?
  private var configureMode: ConfigureMode?
  private(set) var getBrightness: GetBrightness?
  private(set) var setBrightness: SetBrightness?
  private(set) var createAVService: CreateAVService?
  private(set) var readI2C: AVTransfer?
  private(set) var writeI2C: AVTransfer?

  init() {
    let sky = open("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    let cg = open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    let core = open("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
    let brightness = open("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    let io = open("/System/Library/Frameworks/IOKit.framework/IOKit")
    isProMotion = symbol(sky, "SLSIsDisplayModeProMotion")
    isVariableRefresh = symbol(sky, "SLSIsDisplayModeVRR")
    legacyModes = symbol(cg, "CGDisplayAvailableModes")
    displayInfo = symbol(core, "CoreDisplay_DisplayCreateInfoDictionary")
    modeCount = symbol(sky, "SLSGetNumberOfDisplayModes")
    currentModeIndex = symbol(sky, "SLSGetCurrentDisplayMode")
    modeDescription = symbol(sky, "SLSGetDisplayModeDescriptionOfLength")
    configureMode = symbol(sky, "SLSConfigureDisplayMode")
    getBrightness = symbol(brightness, "DisplayServicesGetBrightness")
    setBrightness = symbol(brightness, "DisplayServicesSetBrightness")
    createAVService = symbol(io, "IOAVServiceCreateWithService")
    readI2C = symbol(io, "IOAVServiceReadI2C")
    writeI2C = symbol(io, "IOAVServiceWriteI2C")
  }

  deinit { handles.forEach { dlclose($0) } }

  private func open(_ path: String) -> UnsafeMutableRawPointer? {
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
    handles.append(handle)
    return handle
  }

  private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
    guard let handle, let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }

  func info(_ displayID: UInt32) -> [String: Any] {
    displayInfo?(displayID)?.takeRetainedValue() as? [String: Any] ?? [:]
  }

  func nativeModes(_ displayID: UInt32) -> [DisplayNativeMode] {
    guard let modeCount, let modeDescription, configureMode != nil else { return [] }
    var count: Int32 = 0
    guard modeCount(displayID, &count) == 0, count > 0, count <= 4096 else { return [] }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: DisplayNativeMode.byteCount, alignment: 16)
    defer { buffer.deallocate() }
    return (0..<count).compactMap { index in
      buffer.initializeMemory(as: UInt8.self, repeating: 0, count: DisplayNativeMode.byteCount)
      guard modeDescription(displayID, index, buffer, Int32(DisplayNativeMode.byteCount)) == 0 else { return nil }
      return DisplayNativeMode(index: index, data: Data(bytes: buffer, count: DisplayNativeMode.byteCount))
    }
  }

  func nativeCurrentModeIndex(_ displayID: UInt32) -> Int32? {
    var index: Int32 = -1
    guard currentModeIndex?(displayID, &index) == 0, index >= 0 else { return nil }
    return index
  }

  func nativeModeIndices(_ displayID: UInt32) -> [Int32: Int32] {
    let records = legacyModes?(displayID)?.takeUnretainedValue() as? [[String: Any]] ?? []
    var indices: [Int32: Int32] = [:]
    for record in records {
      guard let index = record["Mode"] as? NSNumber,
        let ioID = record["IODisplayModeID"] as? NSNumber else { continue }
      indices[ioID.int32Value] = index.int32Value
    }
    return indices
  }

  func refreshKind(_ displayID: UInt32, index: Int32) -> DisplayRefreshKind {
    if isProMotion?(displayID, index) == true { return .proMotion }
    if isVariableRefresh?(displayID, index) == true { return .variable }
    return isVariableRefresh == nil ? .unknown : .fixed
  }

  func configureNativeMode(_ index: Int32, displayID: UInt32) -> CGError {
    guard let configureMode else { return .notImplemented }
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success, let configuration else { return begin == .success ? .failure : begin }
    // SkyLight requires a real configuration token, never a connection ID.
    let result = CGError(rawValue: configureMode(configuration, displayID, index)) ?? .failure
    guard result == .success else {
      CGCancelDisplayConfiguration(configuration)
      return result
    }
    return CGCompleteDisplayConfiguration(configuration, .forSession)
  }

  func refreshKinds(_ displayID: UInt32) -> [Int32: DisplayRefreshKind] {
    // SkyLight takes its mode index, which is NOT the I/O mode ID. The legacy
    // dictionaries supply the explicit mapping; never guess it from list order.
    let records = legacyModes?(displayID)?.takeUnretainedValue() as? [[String: Any]] ?? []
    var result: [Int32: DisplayRefreshKind] = [:]
    for record in records {
      guard let index = record["Mode"] as? NSNumber,
        let ioID = record["IODisplayModeID"] as? NSNumber else { continue }
      if isProMotion?(displayID, index.int32Value) == true {
        result[ioID.int32Value] = .proMotion
      } else if isVariableRefresh?(displayID, index.int32Value) == true {
        result[ioID.int32Value] = .variable
      } else if isVariableRefresh != nil {
        result[ioID.int32Value] = .fixed
      }
    }
    return result
  }
}

enum DisplayRefreshKind: String, CaseIterable, Sendable {
  case proMotion = "ProMotion"
  case variable = "Variable Refresh Rate"
  case fixed = "Fixed Refresh Rate"
  case unknown = "Unclassified Refresh Rate"
}
