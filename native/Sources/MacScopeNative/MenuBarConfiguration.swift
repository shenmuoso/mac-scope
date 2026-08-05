import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
  case iconOnly
  case compact

  var id: String { rawValue }
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network
  case temperature
  case systemPower
  case chargingPower
  case fan

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU Usage"
    case .memory: "Memory Usage"
    case .disk: "Disk Activity"
    case .network: "Network Activity"
    case .temperature: "CPU Temperature"
    case .systemPower: "System Power"
    case .chargingPower: "Charging Power"
    case .fan: "Fan Speed"
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    case .temperature: "thermometer.medium"
    case .systemPower: "bolt.fill"
    case .chargingPower: "battery.100percent.bolt"
    case .fan: "fan"
    }
  }
}

enum MenuBarModule: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network
  case temperature
  case systemPower
  case chargingPower
  case fan
  case processes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    case .temperature: "Temperature"
    case .systemPower: "System Power"
    case .chargingPower: "Charging Power"
    case .fan: "Fan Speed"
    case .processes: "Top Processes"
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    case .temperature: "thermometer.medium"
    case .systemPower: "bolt.fill"
    case .chargingPower: "battery.100percent.bolt"
    case .fan: "fan"
    case .processes: "list.number"
    }
  }
}

enum MenuBarProcessSort: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    }
  }
}
