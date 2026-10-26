import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
  case iconOnly
  case compact

  var id: String { rawValue }
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case gpu
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
    case .gpu: "GPU Usage"
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
    case .gpu: "square.3.layers.3d"
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
  case gpu
  case memory
  case disk
  case network
  case temperature
  case systemPower
  case chargingPower
  case fan
  case processes
  case appVolume

  var id: String { rawValue }

  var isDedicatedSection: Bool {
    self == .processes || self == .appVolume
  }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    case .temperature: "Temperature"
    case .systemPower: "System Power"
    case .chargingPower: "Charging Power"
    case .fan: "Fan Speed"
    case .processes: "Top Processes"
    case .appVolume: "App Volume"
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: "cpu"
    case .gpu: "square.3.layers.3d"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    case .temperature: "thermometer.medium"
    case .systemPower: "bolt.fill"
    case .chargingPower: "battery.100percent.bolt"
    case .fan: "fan"
    case .processes: "list.number"
    case .appVolume: "speaker.wave.2"
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
