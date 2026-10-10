import Darwin
import Foundation
import IOKit

enum GPUMetricsReader {
  static let isSupported: Bool = {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
      return false
    }
    var name = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 else {
      return false
    }
    let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self).hasPrefix("Apple M")
  }()

  static func read() -> GPUUsage {
    guard isSupported else { return GPUUsage(state: .unsupported) }
    guard let matching = IOServiceMatching("AGXAccelerator") else { return .unavailable }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
      return .unavailable
    }
    defer { IOObjectRelease(iterator) }

    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
      let statistics = IORegistryEntryCreateCFProperty(
        service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
      )?.takeRetainedValue() as? [String: Any]
      IOObjectRelease(service)
      if let statistics {
        let usage = parse(statistics)
        if usage.state == .available { return usage }
      }
    }
    return .unavailable
  }

  static func parse(_ statistics: [String: Any]) -> GPUUsage {
    guard let total = percent(statistics["Device Utilization %"]) else { return .unavailable }
    return GPUUsage(
      state: .available,
      totalPercent: total,
      rendererPercent: percent(statistics["Renderer Utilization %"]),
      tilerPercent: percent(statistics["Tiler Utilization %"])
    )
  }

  private static func percent(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let percent = number.doubleValue
    guard percent.isFinite, (0...100).contains(percent) else { return nil }
    return percent
  }
}
