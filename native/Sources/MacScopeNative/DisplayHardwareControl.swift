import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

enum DDCFeature: UInt8, CaseIterable, Identifiable, Sendable {
  case brightness = 0x10
  case contrast = 0x12
  case volume = 0x62

  var id: UInt8 { rawValue }
  var title: String {
    switch self {
    case .brightness: "Brightness"
    case .contrast: "Contrast"
    case .volume: "Monitor Volume"
    }
  }
  var symbol: String {
    switch self {
    case .brightness: "sun.max"
    case .contrast: "circle.lefthalf.filled"
    case .volume: "speaker.wave.2"
    }
  }
}

struct DDCValue: Equatable, Sendable {
  let current: UInt16
  let maximum: UInt16
  var percent: Double { Double(current) / Double(maximum) * 100 }
}

enum DDCPacket {
  static func request(_ feature: DDCFeature, value: UInt16? = nil, avService: Bool) -> [UInt8] {
    var bytes: [UInt8]
    if let value {
      bytes = [0x84, 0x03, feature.rawValue, UInt8(value >> 8), UInt8(value & 0xff)]
    } else {
      bytes = [0x82, 0x01, feature.rawValue]
    }
    // IOAVService supplies the source address. Get-VCP uses the AV transport's
    // checksum convention, while Set-VCP and Intel I2C use the full DDC packet.
    let seed: UInt8 = avService && value == nil ? 0x6e : 0x6e ^ 0x51
    bytes.append(bytes.reduce(seed, ^))
    return avService ? bytes : [0x51] + bytes
  }

  static func parse(_ bytes: [UInt8], feature: DDCFeature) -> DDCValue? {
    guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88,
      bytes[2] == 0x02, bytes[3] == 0, bytes[4] == feature.rawValue,
      bytes[5] == 0, bytes.reduce(0x50, ^) == 0 else { return nil }
    let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
    let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    guard maximum > 0, current <= maximum else { return nil }
    return .init(current: current, maximum: maximum)
  }
}

struct DisplayHardwareSnapshot: Sendable {
  let brightness: Double?
  let ddc: [DDCFeature: DDCValue]
  let error: String?

  func percent(for feature: DDCFeature?) -> Double? {
    if let feature { return ddc[feature]?.percent }
    return brightness
  }
}

protocol DisplayHardwareControlling: Sendable {
  func read(displayID: UInt32, identity: String, builtIn: Bool) async -> DisplayHardwareSnapshot
  func setNativeBrightness(_ percent: Double, displayID: UInt32, identity: String) async throws -> Double
  func setDDC(_ feature: DDCFeature, percent: Double, displayID: UInt32, identity: String) async throws -> DDCValue
  func colorConfiguration(_ displayID: UInt32) async -> DisplayColorConfiguration
  func setProfile(_ id: String, displayID: UInt32, identity: String) async throws -> DisplayColorConfiguration
}

// Serial actor keeps DDC timing/retries off the main thread and prevents two
// sliders from interleaving monitor requests. Connections are not cached across
// hot-plug; every operation validates the display identity and resolves it anew.
actor DisplayHardwareControl: DisplayHardwareControlling {
  private let system = DisplaySystemInterfaces()

  func read(displayID: UInt32, identity: String, builtIn: Bool) -> DisplayHardwareSnapshot {
    do {
      try DisplayColorProfiles.validate(displayID, identity: identity)
      if builtIn {
        return .init(brightness: try nativeBrightness(displayID), ddc: [:], error: nil)
      }
      let connection = try connection(displayID)
      var values: [DDCFeature: DDCValue] = [:]
      for feature in DDCFeature.allCases {
        values[feature] = try? read(feature, connection: connection)
      }
      return .init(
        brightness: nil, ddc: values,
        error: values.isEmpty ? DisplayControlError.ddcNoReply.rawValue : nil
      )
    } catch {
      return .init(brightness: nil, ddc: [:], error: error.localizedDescription)
    }
  }

  func setNativeBrightness(_ percent: Double, displayID: UInt32, identity: String) throws -> Double {
    try DisplayColorProfiles.validate(displayID, identity: identity)
    guard percent.isFinite, CGDisplayIsBuiltin(displayID) != 0 else {
      throw DisplayControlError.brightnessUnavailable
    }
    let value = Float(min(100, max(0, percent)) / 100)
    if let write = system.setBrightness, let read = system.getBrightness {
      var previous: Float = 0
      if read(displayID, &previous) == 0 {
        guard write(displayID, value) == 0 else { throw DisplayControlError.brightnessFailed }
        usleep(80000)
        let actual = try nativeBrightness(displayID)
        guard abs(actual - Double(value) * 100) <= 2 else { throw DisplayControlError.brightnessFailed }
        return actual
      }
    }
    guard let entry = try? framebuffer(displayID) else { throw DisplayControlError.brightnessUnavailable }
    defer { IOObjectRelease(entry) }
    guard IODisplaySetFloatParameter(entry, 0, kIODisplayBrightnessKey as CFString, value) == 0 else {
      throw DisplayControlError.brightnessFailed
    }
    let actual = try nativeBrightness(displayID)
    guard abs(actual - Double(value) * 100) <= 2 else { throw DisplayControlError.brightnessFailed }
    return actual
  }

  func setDDC(_ feature: DDCFeature, percent: Double, displayID: UInt32, identity: String) throws -> DDCValue {
    try DisplayColorProfiles.validate(displayID, identity: identity)
    guard percent.isFinite, CGDisplayIsBuiltin(displayID) == 0 else {
      throw DisplayControlError.ddcUnavailable
    }
    let connection = try connection(displayID)
    let previous = try read(feature, connection: connection)
    let value = UInt16((min(100, max(0, percent)) * Double(previous.maximum) / 100).rounded())
    try DisplayColorProfiles.validate(displayID, identity: identity)
    let packet = DDCPacket.request(feature, value: value, avService: connection.av != nil)
    guard transfer(packet, reply: false, connection: connection) != nil else {
      throw DisplayControlError.ddcWriteFailed
    }
    usleep(100000)
    let actual = try read(feature, connection: connection)
    guard abs(Int(actual.current) - Int(value)) <= 1 else { throw DisplayControlError.ddcWriteFailed }
    return actual
  }

  func colorConfiguration(_ displayID: UInt32) -> DisplayColorConfiguration {
    DisplayColorProfiles.read(displayID)
  }

  func setProfile(_ id: String, displayID: UInt32, identity: String) throws -> DisplayColorConfiguration {
    try DisplayColorProfiles.apply(id, displayID: displayID, identity: identity)
    return DisplayColorProfiles.read(displayID)
  }

  private func nativeBrightness(_ displayID: UInt32) throws -> Double {
    var value: Float = 0
    if system.setBrightness != nil, system.getBrightness?(displayID, &value) == 0,
      value.isFinite, (0...1).contains(value) { return Double(value) * 100 }
    guard let entry = try? framebuffer(displayID) else { throw DisplayControlError.brightnessUnavailable }
    defer { IOObjectRelease(entry) }
    guard IODisplayGetFloatParameter(entry, 0, kIODisplayBrightnessKey as CFString, &value) == 0,
      value.isFinite, (0...1).contains(value) else { throw DisplayControlError.brightnessUnavailable }
    return Double(value) * 100
  }

  private func framebuffer(_ displayID: UInt32) throws -> io_service_t {
    guard let path = system.info(displayID)[kIODisplayLocationKey] as? String else {
      throw DisplayControlError.ddcUnavailable
    }
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
    guard entry != 0 else { throw DisplayControlError.disconnected }
    return entry
  }

  private final class Connection {
    let av: CFTypeRef?
    let i2c: io_service_t
    init(av: CFTypeRef? = nil, i2c: io_service_t = 0) { self.av = av; self.i2c = i2c }
    deinit { if i2c != 0 { IOObjectRelease(i2c) } }
  }

  private func connection(_ displayID: UInt32) throws -> Connection {
    guard CGDisplayIsBuiltin(displayID) == 0,
      let location = system.info(displayID)[kIODisplayLocationKey] as? String else {
      throw DisplayControlError.ddcUnavailable
    }
    #if arch(arm64)
    guard let create = system.createAVService, system.readI2C != nil, system.writeI2C != nil else {
      throw DisplayControlError.ddcUnavailable
    }
    let pathComponents = location.split(separator: "/").map { String($0.split(separator: "@")[0]) }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == 0 else {
      throw DisplayControlError.ddcUnavailable
    }
    defer { IOObjectRelease(iterator) }
    var matches: [Connection] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
      defer { IOObjectRelease(entry) }
      guard IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String == "External" else { continue }
      var parent: io_registry_entry_t = 0
      guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == 0 else { continue }
      defer { IOObjectRelease(parent) }
      var name = [CChar](repeating: 0, count: 128)
      guard IORegistryEntryGetName(parent, &name) == 0 else { continue }
      let endpoint = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        .split(separator: ":").first.map(String.init) ?? ""
      // Match the exact display controller, not enumeration order or a monitor
      // name, which would target the wrong screen with identical monitors.
      guard !endpoint.isEmpty, pathComponents.contains(endpoint),
        let service = create(nil, entry)?.takeRetainedValue() else { continue }
      var displayIDs = [UInt32](repeating: 0, count: 32)
      var displayCount: UInt32 = 0
      guard CGGetOnlineDisplayList(32, &displayIDs, &displayCount) == .success else { continue }
      let owners = displayIDs.prefix(Int(displayCount)).filter { id in
        guard let path = system.info(id)[kIODisplayLocationKey] as? String else { return false }
        return path.split(separator: "/").contains { $0.split(separator: "@").first == Substring(endpoint) }
      }
      guard owners == [displayID] else { continue }
      matches.append(Connection(av: service))
    }
    guard matches.count == 1 else { throw DisplayControlError.ddcUnavailable }
    return matches[0]
    #else
    var entry = try framebuffer(displayID)
    defer { IOObjectRelease(entry) }
    while IOObjectConformsTo(entry, "IOFramebuffer") == 0 {
      var parent: io_registry_entry_t = 0
      guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == 0 else {
        throw DisplayControlError.ddcUnavailable
      }
      IOObjectRelease(entry)
      entry = parent
    }
    var count: IOItemCount = 0
    guard IOFBGetI2CInterfaceCount(entry, &count) == 0 else { throw DisplayControlError.ddcUnavailable }
    for bus in 0..<count {
      var interface: io_service_t = 0
      guard IOFBCopyI2CInterfaceForBus(entry, bus, &interface) == 0 else { continue }
      let candidate = Connection(i2c: interface)
      if (try? read(.brightness, connection: candidate)) != nil { return candidate }
    }
    throw DisplayControlError.ddcUnavailable
    #endif
  }

  private func read(_ feature: DDCFeature, connection: Connection) throws -> DDCValue {
    for _ in 0..<3 {
      let packet = DDCPacket.request(feature, avService: connection.av != nil)
      if let bytes = transfer(packet, reply: true, connection: connection),
        let value = DDCPacket.parse(bytes, feature: feature) { return value }
      usleep(20000)
    }
    throw DisplayControlError.ddcNoReply
  }

  private func transfer(_ packet: [UInt8], reply: Bool, connection: Connection) -> [UInt8]? {
    var send = packet
    var receive = [UInt8](repeating: 0, count: 11)
    usleep(10000)
    if let av = connection.av {
      guard let write = system.writeI2C, let read = system.readI2C else { return nil }
      let status = send.withUnsafeMutableBytes { write(av, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
      guard status == 0 else { return nil }
      guard reply else { return [] }
      usleep(60000)
      return receive.withUnsafeMutableBytes { read(av, 0x37, 0, $0.baseAddress!, UInt32($0.count)) } == 0 ? receive : nil
    }
    var bus: IOI2CConnectRef?
    guard IOI2CInterfaceOpen(connection.i2c, 0, &bus) == 0, let bus else { return nil }
    defer { IOI2CInterfaceClose(bus, 0) }
    var request = IOI2CRequest()
    request.sendAddress = 0x6e
    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
    request.sendBytes = UInt32(send.count)
    let sent = send.withUnsafeMutableBytes { buffer in
      request.sendBuffer = vm_address_t(UInt(bitPattern: buffer.baseAddress!))
      return IOI2CSendRequest(bus, 0, &request) == 0 && request.result == 0
    }
    guard sent else { return nil }
    guard reply else { return [] }
    usleep(60000)
    request = IOI2CRequest()
    request.replyAddress = 0x6f
    request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
    request.replyBytes = UInt32(receive.count)
    let received = receive.withUnsafeMutableBytes { buffer in
      request.replyBuffer = vm_address_t(UInt(bitPattern: buffer.baseAddress!))
      return IOI2CSendRequest(bus, 0, &request) == 0 && request.result == 0 && request.replyBytes == 11
    }
    return received ? receive : nil
  }
}
