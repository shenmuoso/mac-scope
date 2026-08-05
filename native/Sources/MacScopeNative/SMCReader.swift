import Darwin
import Foundation
import IOKit

private enum SMCCommand: UInt8 {
  case readBytes = 5
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
  let dataType: String
  let bytes: [UInt8]
}

final class SMCReader {
  private static let selector: UInt32 = 2

  private var connection: io_connect_t = 0
  private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

  deinit {
    close()
  }

  func readCoolingUsage() -> CoolingUsage {
    guard let fanCountValue = readNumericWithReconnect("FNum") else {
      return CoolingUsage(
        state: Self.isKnownFanlessMac ? .fanless : .unavailable,
        fans: []
      )
    }

    let fanCount = max(0, min(16, Int(fanCountValue.rounded())))
    guard fanCount > 0 else {
      return CoolingUsage(state: .fanless, fans: [])
    }

    var fans: [FanReading] = []
    for id in 0..<fanCount {
      guard let currentRPM = plausibleRPM(readNumeric("F\(id)Ac")) else { continue }
      fans.append(
        FanReading(
          id: id,
          name: "Fan \(id + 1)",
          currentRPM: currentRPM,
          minimumRPM: plausibleRPM(readNumeric("F\(id)Mn")),
          maximumRPM: plausibleRPM(readNumeric("F\(id)Mx")),
          targetRPM: plausibleRPM(readNumeric("F\(id)Tg"))
        )
      )
    }

    guard !fans.isEmpty else {
      return CoolingUsage(state: .unavailable, fans: [])
    }
    return CoolingUsage(state: .available, fans: fans)
  }

  private func readNumericWithReconnect(_ key: String) -> Double? {
    if let value = readNumeric(key) { return value }
    close()
    return readNumeric(key)
  }

  private func readNumeric(_ key: String) -> Double? {
    guard let value = readValue(key) else { return nil }
    let bytes = value.bytes

    switch value.dataType {
    case "ui8 ":
      return bytes.first.map(Double.init)
    case "ui16":
      return bytes.count >= 2 ? Double(unsigned16(bytes)) : nil
    case "ui32":
      return bytes.count >= 4 ? Double(unsigned32(bytes)) : nil
    case "flt ":
      guard bytes.count >= 4 else { return nil }
      let raw = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
      return Double(raw)
    case "fpe2":
      guard bytes.count >= 2 else { return nil }
      return Double((Int(bytes[0]) << 6) | (Int(bytes[1]) >> 2))
    default:
      return decodeFixedPoint(value.dataType, bytes: bytes)
    }
  }

  private func readValue(_ key: String) -> SMCValue? {
    guard key.utf8.count == 4, ensureConnection() else { return nil }
    let keyCode = fourCharacterCode(key)

    let info: SMCKeyInfo
    if let cached = keyInfoCache[keyCode] {
      info = cached
    } else {
      var input = SMCKeyData()
      var output = SMCKeyData()
      input.key = keyCode
      input.data8 = SMCCommand.readKeyInfo.rawValue
      guard call(input: &input, output: &output), output.keyInfo.dataSize > 0 else {
        return nil
      }
      info = output.keyInfo
      keyInfoCache[keyCode] = info
    }

    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = keyCode
    input.keyInfo.dataSize = info.dataSize
    input.data8 = SMCCommand.readBytes.rawValue
    guard call(input: &input, output: &output) else { return nil }

    let count = min(Int(info.dataSize), 32)
    let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(count)) }
    return SMCValue(dataType: fourCharacterString(info.dataType), bytes: bytes)
  }

  private func ensureConnection() -> Bool {
    if connection != 0 { return true }
    guard let matching = IOServiceMatching("AppleSMC") else { return false }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }

    var nextConnection: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 0, &nextConnection) == KERN_SUCCESS else {
      return false
    }
    connection = nextConnection
    return true
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

  private func close() {
    guard connection != 0 else { return }
    IOServiceClose(connection)
    connection = 0
    keyInfoCache.removeAll(keepingCapacity: true)
  }

  private func plausibleRPM(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0, value <= 30_000 else { return nil }
    return value
  }

  private func decodeFixedPoint(_ type: String, bytes: [UInt8]) -> Double? {
    guard type.count == 4, type.hasPrefix("fp") || type.hasPrefix("sp"), bytes.count >= 2,
      let fractionalHex = type.last?.hexDigitValue
    else {
      return nil
    }

    let fractionalBits = fractionalHex
    let rawUnsigned = unsigned16(bytes)
    let divisor = pow(2, Double(fractionalBits))
    if type.hasPrefix("sp") {
      return Double(Int16(bitPattern: rawUnsigned)) / divisor
    }
    return Double(rawUnsigned) / divisor
  }

  private func unsigned16(_ bytes: [UInt8]) -> UInt16 {
    UInt16(bytes[0]) << 8 | UInt16(bytes[1])
  }

  private func unsigned32(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
  }

  private func fourCharacterCode(_ string: String) -> UInt32 {
    string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private func fourCharacterString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
  }

  private static var isKnownFanlessMac: Bool {
    #if arch(arm64)
      var size = 0
      guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return false }
      var buffer = [CChar](repeating: 0, count: size)
      guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return false }
      let modelBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return String(decoding: modelBytes, as: UTF8.self).hasPrefix("MacBookAir")
    #else
      return false
    #endif
  }
}
