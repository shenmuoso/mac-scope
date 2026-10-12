import Foundation
import Testing

@testable import MacScopeNative

@Suite("Display controls")
struct DisplayControlTests {
  @Test("Fixed 120 Hz is distinct from ProMotion, and an unknown rate is not adaptive")
  func refreshLabels() {
    #expect(mode(rate: 120, kind: .fixed).refreshLabel == "120 Hz")
    #expect(mode(rate: 120, kind: .proMotion).refreshLabel == "ProMotion")
    #expect(mode(rate: 59.939987, kind: .fixed).refreshLabel == "59.94 Hz")
    #expect(mode(rate: 47.949996, kind: .fixed).refreshLabel == "47.95 Hz")
    #expect(mode(rate: 0, kind: .unknown).refreshLabel != "ProMotion")
    #expect(mode(rate: 0, kind: .unknown).refreshLabel != "Adaptive")
  }

  @Test("All mode criteria are intersected, including density and exact refresh type")
  func filtersIntersect() {
    let filter = DisplayModeFilter(
      resolution: "1512 × 982", density: "HiDPI", refreshKind: "ProMotion", frequency: "120 Hz"
    )
    #expect(filter.matches(mode(rate: 120, kind: .proMotion)))
    #expect(!filter.matches(mode(rate: 120, kind: .fixed)))
    #expect(!filter.matches(mode(rate: 120, kind: .proMotion, hiDPI: false)))
    #expect(!filter.matches(mode(rate: 60, kind: .fixed)))
    var impossible = filter
    impossible.resolution = "1920 × 1080"
    #expect(!impossible.matches(mode(rate: 120, kind: .proMotion)))
  }

  @Test("Default filters preserve density and allow other resolutions and refresh rates")
  func defaultFilters() {
    let current = mode(rate: 120, kind: .proMotion)
    let filter = DisplayModeFilter.current(current)
    #expect(filter.matches(current))
    #expect(filter.matches(mode(rate: 60, kind: .fixed)))
    #expect(!filter.matches(mode(rate: 60, kind: .fixed, hiDPI: false)))
    #expect(filter.resolution.isEmpty)
    #expect(filter.matches(mode(rate: 60, kind: .fixed, width: 1920, height: 1080)))
    #expect(DisplayModeFilter().matches(mode(rate: 120, kind: .fixed, hiDPI: false)))
  }

  @Test("Aspect ratios reflect mode geometry, including nonstandard built-in panels")
  func aspectRatios() {
    #expect(mode(rate: 60, kind: .fixed, width: 2560, height: 1440).aspectRatioLabel == "16:9")
    #expect(mode(rate: 60, kind: .fixed, width: 1920, height: 1200).aspectRatioLabel == "16:10")
    #expect(mode(rate: 120, kind: .proMotion).aspectRatioLabel == "≈1.54:1")
    #expect(mode(rate: 60, kind: .fixed, width: 1080, height: 1920).aspectRatioLabel == "9:16")
    #expect(mode(rate: 60, kind: .fixed, width: 0, height: 0).aspectRatioLabel == "-")
  }

  @Test("Notch labels include rounded MacBook modes but not external or letterboxed modes")
  func notchAspectRatios() {
    for (width, height) in [(1512, 982), (1147, 745), (3024, 1964), (1728, 1117), (1280, 832), (1440, 932)] {
      let notch = mode(rate: 120, kind: .proMotion, width: width, height: height)
      #expect(notch.aspectRatioLabel(isBuiltIn: true) == "Notch")
      #expect(notch.aspectRatioLabel(isBuiltIn: false) != "Notch")
    }
    #expect(mode(rate: 60, kind: .fixed, width: 1920, height: 1200).aspectRatioLabel(isBuiltIn: true) == "16:10")
    #expect(mode(rate: 60, kind: .fixed, width: 2560, height: 1440).aspectRatioLabel(isBuiltIn: true) == "16:9")
    #expect(mode(rate: 60, kind: .fixed, width: 0, height: 0).aspectRatioLabel(isBuiltIn: true) == "-")
  }

  @Test("Monitor reply yields its actual current value and hardware maximum")
  func validDDCReply() {
    // Captured Get-VCP brightness reply from the connected monitor.
    let reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 88, 0x98]
    #expect(DDCPacket.parse(reply, feature: .brightness) == .init(current: 88, maximum: 100))
    #expect(DDCPacket.parse(reply, feature: .contrast) == nil)
    #expect(DDCPacket.parse(Array(reply.dropLast()), feature: .brightness) == nil)
    var corrupted = reply
    corrupted[9] = 87
    #expect(DDCPacket.parse(corrupted, feature: .brightness) == nil)
  }

  @Test("Unsupported, malformed and out-of-range replies never enable controls")
  func invalidDDCReplies() {
    for (index, value): (Int, UInt8) in [(0, 0), (1, 0x87), (2, 0x03), (3, 1), (5, 1), (7, 0), (9, 101)] {
      var reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 88, 0]
      reply[index] = value
      reply[10] = reply.prefix(10).reduce(0x50, ^)
      #expect(DDCPacket.parse(reply, feature: .brightness) == nil)
    }
  }

  @Test("DDC writes encode both bytes of a value and the correct transport checksum")
  func ddcPackets() {
    #expect(DDCPacket.request(.brightness, avService: true) == [0x82, 1, 0x10, 0xfd])
    #expect(DDCPacket.request(.brightness, avService: false) == [0x51, 0x82, 1, 0x10, 0xac])
    let intel = DDCPacket.request(.brightness, value: 0x1234, avService: false)
    #expect(Array(intel[1..<6]) == [0x84, 3, 0x10, 0x12, 0x34])
    #expect(intel.reduce(0x6e, ^) == 0)
    #expect(Array(intel.dropFirst()) == DDCPacket.request(.brightness, value: 0x1234, avService: true))
  }

  @Test("Writes reject disconnected display identities before touching hardware")
  func disconnectedDisplay() async {
    let service = DisplayHardwareControl()
    await #expect(throws: DisplayControlError.disconnected) {
      try await service.setDDC(.brightness, percent: 50, displayID: UInt32.max, identity: "gone")
    }
    await #expect(throws: DisplayControlError.disconnected) {
      try await service.setNativeBrightness(50, displayID: UInt32.max, identity: "gone")
    }
    await #expect(throws: DisplayControlError.disconnected) {
      try await service.setProfile("factory", displayID: UInt32.max, identity: "gone")
    }
  }

  private func mode(rate: Double, kind: DisplayRefreshKind, hiDPI: Bool = true, width: Int = 1512, height: Int = 982) -> DisplayModeSummary {
    .init(
      id: "test", width: width, height: height,
      pixelWidth: hiDPI ? width * 2 : width, pixelHeight: hiDPI ? height * 2 : height,
      refreshRate: rate, refreshKind: kind, isHiDPI: hiDPI, isCurrent: false
    )
  }
}
