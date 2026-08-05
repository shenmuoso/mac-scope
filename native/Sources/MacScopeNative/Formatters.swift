import Foundation

enum DisplayFormat {
  static func bytes(_ value: UInt64) -> String {
    formattedByteCount(Double(value), base: 1_024)
  }

  static func rate(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0 B/s" }
    return "\(formattedByteCount(value, base: 1_000))/s"
  }

  static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", max(0, value))
  }

  static func compactPercent(_ value: Double) -> String {
    String(format: "%.0f%%", max(0, value))
  }

  static func compactRate(_ value: Double) -> String {
    let rate = max(0, value)
    switch rate {
    case 1_000_000_000...:
      return String(format: rate >= 10_000_000_000 ? "%.0fG" : "%.1fG", rate / 1_000_000_000)
    case 1_000_000...:
      return String(format: rate >= 10_000_000 ? "%.0fM" : "%.1fM", rate / 1_000_000)
    case 1_000...:
      return String(format: rate >= 10_000 ? "%.0fK" : "%.1fK", rate / 1_000)
    default:
      return String(format: "%.0fB", rate)
    }
  }

  static func power(_ watts: Double?) -> String? {
    guard let watts, watts.isFinite, watts >= 0 else { return nil }
    return String(format: watts < 100 ? "%.1f W" : "%.0f W", watts)
  }

  static func compactPower(_ watts: Double?) -> String {
    guard let watts, watts.isFinite, watts >= 0 else { return "--" }
    return String(format: watts < 100 ? "%.1fW" : "%.0fW", watts)
  }

  static func fanSpeed(_ rpm: Double?) -> String? {
    guard let rpm, rpm.isFinite, rpm >= 0 else { return nil }
    return "\(Int(rpm.rounded())) RPM"
  }

  static func compactFanSpeed(_ rpm: Double?) -> String {
    guard let rpm, rpm.isFinite, rpm >= 0 else { return "--" }
    return "\(Int(rpm.rounded()))RPM"
  }

  static func temperature(_ celsius: Double?, unit: TemperatureUnit) -> String? {
    guard let celsius, celsius.isFinite else { return nil }
    switch unit {
    case .celsius:
      return String(format: "%.0f°C", celsius)
    case .fahrenheit:
      return String(format: "%.0f°F", celsius * 9 / 5 + 32)
    }
  }

  static func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 {
      return "\(days)d \(hours)h"
    }
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  static func processState(_ value: String) -> String {
    switch value.first {
    case "R": "Running"
    case "S": "Sleeping"
    case "I": "Idle"
    case "T": "Stopped"
    case "Z": "Zombie"
    case "U": "Waiting"
    default: "Unknown"
    }
  }

  static func date(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: value)
  }

  private static var appLocale: Locale {
    let identifier = UserDefaults.standard.string(forKey: "native.language") ?? "en"
    return Locale(identifier: identifier)
  }

  private static func formattedByteCount(_ value: Double, base: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var scaled = max(0, value)
    var unitIndex = 0
    while scaled >= base, unitIndex < units.count - 1 {
      scaled /= base
      unitIndex += 1
    }

    let formatter = NumberFormatter()
    formatter.locale = appLocale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = scaled >= 100 ? 1 : 2
    let number = formatter.string(from: NSNumber(value: scaled)) ?? "0"
    return "\(number) \(units[unitIndex])"
  }
}
