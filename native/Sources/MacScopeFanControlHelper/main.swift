import Darwin
import Foundation
import IOKit

private enum SMCCommand: UInt8 {
  case readBytes = 5
  case writeBytes = 6
  case readKeyInfo = 9
}

private struct SMCVersion {
  var major: UInt8 = 0
  var minor: UInt8 = 0
  var build: UInt8 = 0
  var reserved: UInt8 = 0
  var release: UInt16 = 0
}

private struct SMCPLimitData {
  var version: UInt16 = 0
  var length: UInt16 = 0
  var cpuPLimit: UInt32 = 0
  var gpuPLimit: UInt32 = 0
  var memoryPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
  var dataSize: UInt32 = 0
  var dataType: UInt32 = 0
  var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
  typealias Bytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  var key: UInt32 = 0
  var version = SMCVersion()
  var pLimitData = SMCPLimitData()
  var keyInfo = SMCKeyInfo()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: Bytes = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
  )
}

private struct SMCValue {
  let key: String
  let dataType: String
  let dataSize: UInt32
  var bytes: [UInt8]
}

private final class SMCFanController {
  private static let selector: UInt32 = 2
  private var connection: io_connect_t = 0
  private var lowerCaseModeKey: Bool?

  deinit {
    if connection != 0 { IOServiceClose(connection) }
  }

  func applyMaximumCooling() throws -> [Int] {
    guard let rawCount = numericValue(for: "FNum") else {
      throw HelperError.message("Fan count is unavailable.")
    }
    let count = max(0, min(16, Int(rawCount.rounded())))
    guard count > 0 else { throw HelperError.message("This Mac has no controllable fan.") }

    var maximums: [Int] = []
    for id in 0..<count {
      guard
        let maximum = numericValue(for: "F\(id)Mx"),
        maximum.isFinite,
        maximum >= 1_000,
        maximum <= 30_000,
        let target = readValue("F\(id)Tg"),
        (target.dataType == "flt " && target.bytes.count >= 4)
          || (target.dataType == "fpe2" && target.bytes.count >= 2)
      else {
        throw HelperError.message("Fan \(id + 1) does not expose a verifiable target speed.")
      }
      maximums.append(Int(maximum.rounded()))
    }

    do {
      for id in 0..<count {
        try setManualMode(id: id)
        try setTargetSpeed(id: id, rpm: maximums[id])
        guard
          let verified = numericValue(for: "F\(id)Tg"),
          abs(verified - Double(maximums[id])) <= max(100, Double(maximums[id]) * 0.05)
        else {
          throw HelperError.message("Fan \(id + 1) did not accept the requested speed.")
        }
      }
    } catch {
      try? restoreAutomaticControl(fanCount: count)
      throw error
    }
    return maximums
  }

  func restoreAutomaticControl() throws {
    guard let rawCount = numericValue(for: "FNum") else {
      throw HelperError.message("Fan count is unavailable.")
    }
    let count = max(0, min(16, Int(rawCount.rounded())))
    guard count > 0 else { throw HelperError.message("This Mac has no controllable fan.") }
    try restoreAutomaticControl(fanCount: count)
  }

  private func restoreAutomaticControl(fanCount: Int) throws {
    var firstError: Error?

    #if arch(arm64)
      if readValue("Ftst") != nil {
        try writeFirstByteWithRetry(0, to: "Ftst", attempts: 10)
        guard numericValue(for: "Ftst") == 0 else {
          throw HelperError.message("System automatic fan control could not be verified.")
        }
      } else {
        for id in 0..<fanCount {
          do {
            let key = fanModeKey(id)
            try writeFirstByteWithRetry(0, to: key, attempts: 10)
            guard numericValue(for: key) == 0 else {
              throw HelperError.message("Fan \(id + 1) automatic mode could not be verified.")
            }
          } catch {
            firstError = firstError ?? error
          }
        }
      }
    #else
      for id in 0..<fanCount where readValue("F\(id)Md") != nil {
        do {
          try writeFirstByte(0, to: "F\(id)Md")
          guard numericValue(for: "F\(id)Md") == 0 else {
            throw HelperError.message("Fan \(id + 1) automatic mode could not be verified.")
          }
        } catch {
          firstError = firstError ?? error
        }
      }
      if var globalMode = readValue("FS! ") {
        globalMode.bytes = Array(repeating: 0, count: max(Int(globalMode.dataSize), 2))
        do {
          try writeValue(globalMode)
          guard numericValue(for: "FS! ") == 0 else {
            throw HelperError.message("System automatic fan control could not be verified.")
          }
        } catch {
          firstError = firstError ?? error
        }
      }
    #endif

    if let firstError { throw firstError }
  }

  private func setManualMode(id: Int) throws {
    #if arch(arm64)
      let key = fanModeKey(id)
      do {
        try writeFirstByte(1, to: key)
        if numericValue(for: key) == 1 { return }
      } catch {
        guard readValue("Ftst") != nil else { throw error }
      }

      try writeFirstByteWithRetry(1, to: "Ftst", attempts: 100)
      usleep(3_000_000)
      try writeFirstByteWithRetry(1, to: key, attempts: 300)
      guard numericValue(for: key) == 1 else {
        throw HelperError.message("Fan \(id + 1) manual mode could not be verified.")
      }
    #else
      var verifiedMode = false
      if readValue("F\(id)Md") != nil {
        try writeFirstByte(1, to: "F\(id)Md")
        guard numericValue(for: "F\(id)Md") == 1 else {
          throw HelperError.message("Fan \(id + 1) manual mode could not be verified.")
        }
        verifiedMode = true
      }
      if id < 8, var globalMode = readValue("FS! ") {
        while globalMode.bytes.count < 2 { globalMode.bytes.append(0) }
        globalMode.bytes[1] |= UInt8(1 << id)
        try writeValue(globalMode)
        guard let modes = numericValue(for: "FS! "), Int(modes) & (1 << id) != 0 else {
          throw HelperError.message("Fan \(id + 1) manual mode could not be verified.")
        }
        verifiedMode = true
      }
      guard verifiedMode else {
        throw HelperError.message("Fan \(id + 1) manual mode is unavailable.")
      }
    #endif
  }

  private func setTargetSpeed(id: Int, rpm: Int) throws {
    guard var value = readValue("F\(id)Tg") else {
      throw HelperError.message("Fan \(id + 1) target speed is unavailable.")
    }
    switch value.dataType {
    case "flt ":
      let encoded = withUnsafeBytes(of: Float(rpm)) { Array($0) }
      value.bytes.replaceSubrange(0..<min(4, value.bytes.count), with: encoded.prefix(4))
    case "fpe2":
      guard value.bytes.count >= 2 else {
        throw HelperError.message("Fan \(id + 1) target speed has an invalid format.")
      }
      value.bytes[0] = UInt8((rpm >> 6) & 0xff)
      value.bytes[1] = UInt8((rpm << 2) & 0xff)
    default:
      throw HelperError.message("Fan \(id + 1) target speed format is unsupported.")
    }
    try writeValueWithRetry(value, attempts: 10)
  }

  private func fanModeKey(_ id: Int) -> String {
    #if arch(arm64)
      if lowerCaseModeKey == nil {
        lowerCaseModeKey = readValue("F0md") != nil
      }
      return lowerCaseModeKey == true ? "F\(id)md" : "F\(id)Md"
    #else
      return "F\(id)Md"
    #endif
  }

  private func writeFirstByte(_ byte: UInt8, to key: String) throws {
    guard var value = readValue(key), !value.bytes.isEmpty else {
      throw HelperError.message("SMC key \(key) is unavailable.")
    }
    value.bytes[0] = byte
    try writeValue(value)
  }

  private func writeFirstByteWithRetry(_ byte: UInt8, to key: String, attempts: Int) throws {
    var lastError: Error = HelperError.message("SMC key \(key) could not be written.")
    for attempt in 0..<attempts {
      do {
        try writeFirstByte(byte, to: key)
        return
      } catch {
        lastError = error
        if attempt + 1 < attempts { usleep(100_000) }
      }
    }
    throw lastError
  }

  private func writeValueWithRetry(_ value: SMCValue, attempts: Int) throws {
    var lastError: Error = HelperError.message("SMC key \(value.key) could not be written.")
    for attempt in 0..<attempts {
      do {
        try writeValue(value)
        return
      } catch {
        lastError = error
        if attempt + 1 < attempts { usleep(50_000) }
      }
    }
    throw lastError
  }

  private func numericValue(for key: String) -> Double? {
    guard let value = readValue(key) else { return nil }
    switch value.dataType {
    case "ui8 ":
      return value.bytes.first.map(Double.init)
    case "ui16":
      guard value.bytes.count >= 2 else { return nil }
      return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
    case "ui32":
      guard value.bytes.count >= 4 else { return nil }
      return Double(
        UInt32(value.bytes[0]) << 24 | UInt32(value.bytes[1]) << 16
          | UInt32(value.bytes[2]) << 8 | UInt32(value.bytes[3])
      )
    case "flt ":
      guard value.bytes.count >= 4 else { return nil }
      return Double(value.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    case "fpe2":
      guard value.bytes.count >= 2 else { return nil }
      return Double((Int(value.bytes[0]) << 6) | (Int(value.bytes[1]) >> 2))
    default:
      return nil
    }
  }

  private func readValue(_ key: String) -> SMCValue? {
    guard key.utf8.count == 4, ensureConnection() else { return nil }
    var infoInput = SMCKeyData()
    var infoOutput = SMCKeyData()
    infoInput.key = fourCharacterCode(key)
    infoInput.data8 = SMCCommand.readKeyInfo.rawValue
    guard call(input: &infoInput, output: &infoOutput), infoOutput.keyInfo.dataSize > 0 else {
      return nil
    }

    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = fourCharacterCode(key)
    input.keyInfo.dataSize = infoOutput.keyInfo.dataSize
    input.data8 = SMCCommand.readBytes.rawValue
    guard call(input: &input, output: &output) else { return nil }

    let count = min(Int(infoOutput.keyInfo.dataSize), 32)
    let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(count)) }
    return SMCValue(
      key: key,
      dataType: fourCharacterString(infoOutput.keyInfo.dataType),
      dataSize: infoOutput.keyInfo.dataSize,
      bytes: bytes
    )
  }

  private func writeValue(_ value: SMCValue) throws {
    guard ensureConnection(), value.dataSize > 0, value.dataSize <= 32 else {
      throw HelperError.message("SMC connection is unavailable.")
    }
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = fourCharacterCode(value.key)
    input.keyInfo.dataSize = value.dataSize
    input.data8 = SMCCommand.writeBytes.rawValue
    withUnsafeMutableBytes(of: &input.bytes) { destination in
      destination.copyBytes(from: value.bytes.prefix(min(destination.count, value.bytes.count)))
    }
    guard call(input: &input, output: &output) else {
      throw HelperError.message("SMC rejected key \(value.key).")
    }
  }

  private func ensureConnection() -> Bool {
    if connection != 0 { return true }
    guard let matching = IOServiceMatching("AppleSMC") else { return false }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
  }

  private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
    var outputSize = MemoryLayout<SMCKeyData>.stride
    let result = IOConnectCallStructMethod(
      connection,
      Self.selector,
      &input,
      MemoryLayout<SMCKeyData>.stride,
      &output,
      &outputSize
    )
    return result == KERN_SUCCESS && output.result == 0
  }

  private func fourCharacterCode(_ string: String) -> UInt32 {
    string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private func fourCharacterString(_ value: UInt32) -> String {
    String(
      bytes: [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
      ],
      encoding: .ascii
    ) ?? ""
  }
}

private enum HelperError: Error, LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

private struct HelperStatus: Codable {
  let state: String
  let message: String?
  let startedAt: TimeInterval?
  let endsAt: TimeInterval?
  let maximumRPM: Int?
  let helperPID: Int32
  let updatedAt: TimeInterval
}

private struct Arguments {
  enum Mode: String {
    case maximum
    case restore
  }

  let mode: Mode
  let duration: TimeInterval
  let ownerPID: pid_t
  let ownerUID: uid_t
  let sessionURL: URL

  init?() {
    let values = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
      guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else {
        return nil
      }
      return values[index + 1]
    }
    guard
      let modeText = value(after: "--mode"),
      let mode = Mode(rawValue: modeText),
      let durationText = value(after: "--duration"),
      let duration = TimeInterval(durationText),
      [900, 1800, 3600].contains(duration),
      let pidText = value(after: "--owner-pid"),
      let ownerPID = pid_t(pidText), ownerPID > 1,
      let uidText = value(after: "--owner-uid"),
      let ownerUID = uid_t(uidText), ownerUID > 0,
      let sessionPath = value(after: "--session")
    else {
      return nil
    }
    self.mode = mode
    self.duration = duration
    self.ownerPID = ownerPID
    self.ownerUID = ownerUID
    sessionURL = URL(fileURLWithPath: sessionPath, isDirectory: true).standardizedFileURL
  }
}

private final class FanControlSession {
  private let arguments: Arguments
  private let controller = SMCFanController()
  private var sessionDirectoryFD: Int32 = -1

  init(arguments: Arguments) {
    self.arguments = arguments
  }

  deinit {
    if sessionDirectoryFD >= 0 { close(sessionDirectoryFD) }
  }

  func run() -> Int32 {
    guard getuid() == 0 else { return 77 }
    guard validateSessionDirectory() else { return 78 }

    let startedAt = Date()
    let endsAt = startedAt.addingTimeInterval(arguments.duration)
    writeStatus(
      HelperStatus(
        state: "starting",
        message: nil,
        startedAt: startedAt.timeIntervalSince1970,
        endsAt: endsAt.timeIntervalSince1970,
        maximumRPM: nil,
        helperPID: getpid(),
        updatedAt: startedAt.timeIntervalSince1970
      )
    )

    if arguments.mode == .restore {
      do {
        try controller.restoreAutomaticControl()
        writeStatus(
          HelperStatus(
            state: "restored",
            message: "System automatic fan control was restored.",
            startedAt: startedAt.timeIntervalSince1970,
            endsAt: Date().timeIntervalSince1970,
            maximumRPM: nil,
            helperPID: getpid(),
            updatedAt: Date().timeIntervalSince1970
          )
        )
        return 0
      } catch {
        writeStatus(
          HelperStatus(
            state: "failed",
            message: error.localizedDescription,
            startedAt: startedAt.timeIntervalSince1970,
            endsAt: Date().timeIntervalSince1970,
            maximumRPM: nil,
            helperPID: getpid(),
            updatedAt: Date().timeIntervalSince1970
          )
        )
        return 1
      }
    }

    if stopWasRequested || !ownerIsRunning || heartbeatIsStale {
      writeStatus(
        HelperStatus(
          state: "restored",
          message: "Maximum cooling was cancelled before it started.",
          startedAt: startedAt.timeIntervalSince1970,
          endsAt: Date().timeIntervalSince1970,
          maximumRPM: nil,
          helperPID: getpid(),
          updatedAt: Date().timeIntervalSince1970
        )
      )
      return 0
    }

    do {
      let maximums = try controller.applyMaximumCooling()

      var restoreReason = "Maximum cooling ended. System automatic control was restored."
      while Date() < endsAt {
        writeStatus(
          HelperStatus(
            state: "active",
            message: nil,
            startedAt: startedAt.timeIntervalSince1970,
            endsAt: endsAt.timeIntervalSince1970,
            maximumRPM: maximums.max(),
            helperPID: getpid(),
            updatedAt: Date().timeIntervalSince1970
          )
        )
        if stopWasRequested {
          restoreReason = "Maximum cooling was stopped. System automatic control was restored."
          break
        }
        if !ownerIsRunning || heartbeatIsStale {
          restoreReason = "MacScope stopped responding. System automatic control was restored."
          break
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
          restoreReason = "macOS reported thermal pressure. System automatic control was restored."
          break
        default:
          sleep(1)
          continue
        }
        break
      }

      try controller.restoreAutomaticControl()
      writeStatus(
        HelperStatus(
          state: "restored",
          message: restoreReason,
          startedAt: startedAt.timeIntervalSince1970,
          endsAt: Date().timeIntervalSince1970,
          maximumRPM: maximums.max(),
          helperPID: getpid(),
          updatedAt: Date().timeIntervalSince1970
        )
      )
      return 0
    } catch {
      try? controller.restoreAutomaticControl()
      writeStatus(
        HelperStatus(
          state: "failed",
          message: error.localizedDescription,
          startedAt: startedAt.timeIntervalSince1970,
          endsAt: Date().timeIntervalSince1970,
          maximumRPM: nil,
          helperPID: getpid(),
          updatedAt: Date().timeIntervalSince1970
        )
      )
      return 1
    }
  }

  private var ownerIsRunning: Bool {
    kill(arguments.ownerPID, 0) == 0 || errno == EPERM
  }

  private var stopWasRequested: Bool {
    guard sessionDirectoryFD >= 0 else { return true }
    var info = stat()
    guard fstatat(sessionDirectoryFD, "stop", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      return false
    }
    return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == arguments.ownerUID
  }

  private var heartbeatIsStale: Bool {
    guard sessionDirectoryFD >= 0 else { return true }
    var info = stat()
    guard
      fstatat(sessionDirectoryFD, "heartbeat", &info, AT_SYMLINK_NOFOLLOW) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == arguments.ownerUID
    else { return true }
    return Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > 8
  }

  private func validateSessionDirectory() -> Bool {
    guard let passwordEntry = getpwuid(arguments.ownerUID), let homePointer = passwordEntry.pointee.pw_dir
    else { return false }
    let home = String(cString: homePointer)
    let expectedRoot = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Caches/com.shenmuoso.macscope/FanControl", isDirectory: true)
      .standardizedFileURL.path + "/"
    guard arguments.sessionURL.path.hasPrefix(expectedRoot) else { return false }

    let descriptor = open(
      arguments.sessionURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      close(descriptor)
      return false
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0 else {
      close(descriptor)
      return false
    }
    guard info.st_uid == arguments.ownerUID else {
      close(descriptor)
      return false
    }
    sessionDirectoryFD = descriptor
    return true
  }

  @discardableResult
  private func writeStatus(_ status: HelperStatus) -> Bool {
    guard sessionDirectoryFD >= 0, let data = try? JSONEncoder().encode(status) else {
      return false
    }
    let temporaryName = "status.\(getpid()).tmp"
    temporaryName.withCString { _ = unlinkat(sessionDirectoryFD, $0, 0) }
    let descriptor = temporaryName.withCString {
      openat(
        sessionDirectoryFD,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o644)
      )
    }
    guard descriptor >= 0 else { return false }
    var wroteAllBytes = true
    _ = fchmod(descriptor, mode_t(0o644))
    data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
        guard count > 0 else {
          wroteAllBytes = false
          return
        }
        offset += count
      }
    }
    if wroteAllBytes { _ = fsync(descriptor) }
    close(descriptor)
    guard wroteAllBytes else {
      temporaryName.withCString { _ = unlinkat(sessionDirectoryFD, $0, 0) }
      return false
    }
    let renamed = temporaryName.withCString { temporaryPointer in
      "status.json".withCString { statusPointer in
        renameat(sessionDirectoryFD, temporaryPointer, sessionDirectoryFD, statusPointer)
      }
    }
    guard renamed == 0 else {
      temporaryName.withCString { _ = unlinkat(sessionDirectoryFD, $0, 0) }
      return false
    }
    return true
  }
}

guard let arguments = Arguments() else {
  fputs("Invalid fan-control arguments.\n", stderr)
  exit(64)
}
exit(FanControlSession(arguments: arguments).run())
