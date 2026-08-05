import Foundation

enum ThermalStatus: String, Sendable {
  case unavailable
  case normal
  case warm
  case hot
}

struct TemperatureUsage: Sendable {
  var socCelsius: Double?
  var batteryCelsius: Double?
  var storageCelsius: Double?
  var status: ThermalStatus

  static let unavailable = TemperatureUsage(
    socCelsius: nil,
    batteryCelsius: nil,
    storageCelsius: nil,
    status: .unavailable
  )
}

struct CPUUsage: Sendable {
  var total: Double
  var user: Double
  var system: Double
  var temperature: TemperatureUsage
}

struct PowerUsage: Sendable, Equatable {
  var systemWatts: Double?
  var chargingWatts: Double?
  var adapterInputWatts: Double?
  var hasBattery: Bool
  var isExternalPowerConnected: Bool?
  var isCharging: Bool

  static let unavailable = PowerUsage(
    systemWatts: nil,
    chargingWatts: nil,
    adapterInputWatts: nil,
    hasBattery: false,
    isExternalPowerConnected: nil,
    isCharging: false
  )
}

enum FanSupportState: String, Sendable {
  case available
  case fanless
  case unavailable
}

struct FanReading: Identifiable, Sendable {
  let id: Int
  let name: String
  let currentRPM: Double
  let minimumRPM: Double?
  let maximumRPM: Double?
  let targetRPM: Double?
}

struct CoolingUsage: Sendable {
  let state: FanSupportState
  let fans: [FanReading]

  static let unavailable = CoolingUsage(state: .unavailable, fans: [])
}

struct MemoryUsage: Sendable {
  var used: UInt64
  var available: UInt64
  var total: UInt64

  var fraction: Double {
    total == 0 ? 0 : Double(used) / Double(total)
  }
}

struct DiskUsage: Sendable {
  var used: UInt64
  var available: UInt64
  var total: UInt64
  var readRate: Double
  var writeRate: Double

  var fraction: Double {
    total == 0 ? 0 : Double(used) / Double(total)
  }
}

struct NetworkUsage: Sendable {
  var downloadRate: Double
  var uploadRate: Double
  var downloadTotal: UInt64
  var uploadTotal: UInt64
}

enum ProcessOrigin: String, CaseIterable, Hashable, Sendable {
  case macOSSystem
  case installedSoftware
  case userTool
  case unknown
}

struct SoftwareIdentity: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let bundleIdentifier: String?
  let bundleURL: URL?
  let origin: ProcessOrigin

  static func == (lhs: SoftwareIdentity, rhs: SoftwareIdentity) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

struct ProcessRow: Identifiable, Hashable, Sendable {
  let pid: Int32
  let parentPID: Int32
  let name: String
  let user: String
  let state: String
  let executablePath: String
  let cpuPercent: Double
  let memoryBytes: UInt64
  let diskReadRate: Double
  let diskWriteRate: Double
  let diskReadTotal: UInt64
  let diskWriteTotal: UInt64
  let networkDownloadRate: Double
  let networkUploadRate: Double
  let networkDownloadTotal: UInt64
  let networkUploadTotal: UInt64
  let threadCount: Int
  let runtime: TimeInterval
  let software: SoftwareIdentity

  var id: Int32 { pid }

  func replacing(software: SoftwareIdentity) -> ProcessRow {
    ProcessRow(
      pid: pid,
      parentPID: parentPID,
      name: name,
      user: user,
      state: state,
      executablePath: executablePath,
      cpuPercent: cpuPercent,
      memoryBytes: memoryBytes,
      diskReadRate: diskReadRate,
      diskWriteRate: diskWriteRate,
      diskReadTotal: diskReadTotal,
      diskWriteTotal: diskWriteTotal,
      networkDownloadRate: networkDownloadRate,
      networkUploadRate: networkUploadRate,
      networkDownloadTotal: networkDownloadTotal,
      networkUploadTotal: networkUploadTotal,
      threadCount: threadCount,
      runtime: runtime,
      software: software
    )
  }
}

struct SoftwareProcessGroup: Identifiable, Hashable, Sendable {
  let software: SoftwareIdentity
  let processes: [ProcessRow]

  var id: SoftwareIdentity.ID { software.id }
  var cpuPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
  var memoryBytes: UInt64 {
    processes.reduce(0) { total, process in
      let (sum, overflow) = total.addingReportingOverflow(process.memoryBytes)
      return overflow ? UInt64.max : sum
    }
  }
  var diskRate: Double {
    processes.reduce(0) { $0 + $1.diskReadRate + $1.diskWriteRate }
  }
  var networkRate: Double {
    processes.reduce(0) { $0 + $1.networkDownloadRate + $1.networkUploadRate }
  }

  static func groups(from processes: [ProcessRow]) -> [SoftwareProcessGroup] {
    Dictionary(grouping: processes, by: \.software).map { software, members in
      SoftwareProcessGroup(
        software: software,
        processes: members
      )
    }
  }
}

enum SoftwareSortField: String, CaseIterable, Hashable, Sendable {
  case name
  case processCount
  case cpu
  case memory
  case disk
  case network

  var defaultDirection: SoftwareSortDirection {
    self == .name ? .ascending : .descending
  }
}

enum SoftwareSortDirection: Hashable, Sendable {
  case ascending
  case descending

  mutating func toggle() {
    self = self == .ascending ? .descending : .ascending
  }
}

struct SoftwareSortDescriptor: Hashable, Sendable {
  var field: SoftwareSortField
  var direction: SoftwareSortDirection

  static let initial = SoftwareSortDescriptor(field: .cpu, direction: .descending)

  mutating func select(_ selectedField: SoftwareSortField) {
    if field == selectedField {
      direction.toggle()
    } else {
      field = selectedField
      direction = selectedField.defaultDirection
    }
  }

  func sorted(groups: [SoftwareProcessGroup]) -> [SoftwareProcessGroup] {
    groups.sorted(by: groupComesFirst)
  }

  func sorted(processes: [ProcessRow]) -> [ProcessRow] {
    processes.sorted(by: processComesFirst)
  }

  private func groupComesFirst(_ lhs: SoftwareProcessGroup, _ rhs: SoftwareProcessGroup) -> Bool {
    let primaryOrder: Bool?
    switch field {
    case .name:
      primaryOrder = compare(lhs.software.name, rhs.software.name)
    case .processCount:
      primaryOrder = compare(lhs.processes.count, rhs.processes.count)
    case .cpu:
      primaryOrder = compare(lhs.cpuPercent, rhs.cpuPercent)
    case .memory:
      primaryOrder = compare(lhs.memoryBytes, rhs.memoryBytes)
    case .disk:
      primaryOrder = compare(lhs.diskRate, rhs.diskRate)
    case .network:
      primaryOrder = compare(lhs.networkRate, rhs.networkRate)
    }
    if let primaryOrder { return primaryOrder }

    let nameOrder = ascendingStringOrder(lhs.software.name, rhs.software.name)
    if let nameOrder { return nameOrder }
    return lhs.id < rhs.id
  }

  private func processComesFirst(_ lhs: ProcessRow, _ rhs: ProcessRow) -> Bool {
    let primaryOrder: Bool?
    switch field {
    case .name:
      primaryOrder = compare(lhs.name, rhs.name)
    case .processCount:
      primaryOrder = compare(lhs.pid, rhs.pid)
    case .cpu:
      primaryOrder = compare(lhs.cpuPercent, rhs.cpuPercent)
    case .memory:
      primaryOrder = compare(lhs.memoryBytes, rhs.memoryBytes)
    case .disk:
      primaryOrder = compare(
        lhs.diskReadRate + lhs.diskWriteRate,
        rhs.diskReadRate + rhs.diskWriteRate
      )
    case .network:
      primaryOrder = compare(
        lhs.networkDownloadRate + lhs.networkUploadRate,
        rhs.networkDownloadRate + rhs.networkUploadRate
      )
    }
    if let primaryOrder { return primaryOrder }

    let nameOrder = ascendingStringOrder(lhs.name, rhs.name)
    if let nameOrder { return nameOrder }
    return lhs.pid < rhs.pid
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
    guard lhs != rhs else { return nil }
    switch direction {
    case .ascending: return lhs < rhs
    case .descending: return lhs > rhs
    }
  }

  private func compare(_ lhs: String, _ rhs: String) -> Bool? {
    let result = lhs.localizedStandardCompare(rhs)
    guard result != .orderedSame else { return nil }
    switch direction {
    case .ascending: return result == .orderedAscending
    case .descending: return result == .orderedDescending
    }
  }

  private func ascendingStringOrder(_ lhs: String, _ rhs: String) -> Bool? {
    let result = lhs.localizedStandardCompare(rhs)
    guard result != .orderedSame else { return nil }
    return result == .orderedAscending
  }
}

struct ProcessHistoryPoint: Identifiable, Sendable {
  let timestamp: Date
  let cpuPercent: Double
  let memoryBytes: UInt64
  let diskRate: Double
  let networkRate: Double

  var id: Date { timestamp }
}

struct SystemHistoryPoint: Identifiable, Sendable {
  let timestamp: Date
  let cpuPercent: Double
  let memoryPercent: Double
  let diskReadRate: Double
  let diskWriteRate: Double
  let networkDownloadRate: Double
  let networkUploadRate: Double
  let temperatureCelsius: Double?
  let systemPowerWatts: Double?
  let chargingPowerWatts: Double?
  let fanReadings: [FanHistoryReading]

  var id: Date { timestamp }
}

struct FanHistoryReading: Sendable {
  let id: Int
  let rpm: Double
}

struct SystemSnapshot: Sendable {
  var timestamp: Date
  var cpu: CPUUsage
  var memory: MemoryUsage
  var disk: DiskUsage
  var network: NetworkUsage
  var power: PowerUsage
  var cooling: CoolingUsage
  var processes: [ProcessRow]

  static let empty = SystemSnapshot(
    timestamp: .now,
    cpu: CPUUsage(total: 0, user: 0, system: 0, temperature: .unavailable),
    memory: MemoryUsage(used: 0, available: 0, total: 0),
    disk: DiskUsage(used: 0, available: 0, total: 0, readRate: 0, writeRate: 0),
    network: NetworkUsage(downloadRate: 0, uploadRate: 0, downloadTotal: 0, uploadTotal: 0),
    power: .unavailable,
    cooling: .unavailable,
    processes: []
  )
}
