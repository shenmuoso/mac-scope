import Darwin
import Foundation
import IOKit

@_silgen_name("proc_pid_rusage")
private func rawProcPIDRUsage(
  _ pid: Int32,
  _ flavor: Int32,
  _ buffer: UnsafeMutableRawPointer
) -> Int32

private typealias HIDClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
private typealias HIDClientSetMatching =
  @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
private typealias HIDClientCopyServices =
  @convention(c) (UnsafeMutableRawPointer?) -> UnsafeRawPointer?
private typealias HIDServiceCopyProperty =
  @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
private typealias HIDServiceCopyEvent =
  @convention(c) (UnsafeRawPointer?, Int64, Int32, Int64) -> UnsafeRawPointer?
private typealias HIDEventGetFloatValue = @convention(c) (UnsafeRawPointer?, Int64) -> Double

private struct CPUTicks {
  var user: UInt64
  var system: UInt64
  var idle: UInt64
}

private struct ByteCounters {
  var read: UInt64
  var written: UInt64
}

actor SystemSampler {
  private var previousCPU: CPUTicks?
  private var previousDisk: ByteCounters?
  private var previousNetwork: ByteCounters?
  private var previousProcessDisk: [Int32: ByteCounters] = [:]
  private var previousProcessNetwork: [Int32: ByteCounters] = [:]
  private var cachedProcessPaths: [Int32: (command: String, path: String)] = [:]
  private var processClassifier = ProcessClassifier()
  private var previousTime = ProcessInfo.processInfo.systemUptime
  private var previousProcessTime = ProcessInfo.processInfo.systemUptime
  private var temperature = TemperatureUsage.unavailable
  private var temperatureUpdatedAt = -TimeInterval.infinity
  private var power = PowerUsage.unavailable
  private var powerUpdatedAt = -TimeInterval.infinity

  func sampleMetrics() -> SystemSnapshot {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, now - previousTime)
    if now - temperatureUpdatedAt >= 2 {
      temperature = readTemperatureUsage()
      temperatureUpdatedAt = now
    }
    if now - powerUpdatedAt >= 1 {
      power = PowerMetricsReader.read()
      powerUpdatedAt = now
    }
    let cpuTicks = readCPUTicks()
    let diskCounters = readDiskCounters()
    let networkCounters = readNetworkCounters()
    let cpu = calculateCPU(
      current: cpuTicks,
      previous: previousCPU,
      temperature: temperature
    )
    let memory = readMemoryUsage()
    let diskCapacity = readDiskCapacity()
    let disk = DiskUsage(
      used: diskCapacity.used,
      available: diskCapacity.available,
      total: diskCapacity.total,
      readRate: rate(current: diskCounters.read, previous: previousDisk?.read, elapsed: elapsed),
      writeRate: rate(
        current: diskCounters.written,
        previous: previousDisk?.written,
        elapsed: elapsed
      )
    )
    let network = NetworkUsage(
      downloadRate: rate(
        current: networkCounters.read,
        previous: previousNetwork?.read,
        elapsed: elapsed
      ),
      uploadRate: rate(
        current: networkCounters.written,
        previous: previousNetwork?.written,
        elapsed: elapsed
      ),
      downloadTotal: networkCounters.read,
      uploadTotal: networkCounters.written
    )

    previousCPU = cpuTicks
    previousDisk = diskCounters
    previousNetwork = networkCounters
    previousTime = now

    return SystemSnapshot(
      timestamp: .now,
      cpu: cpu,
      memory: memory,
      disk: disk,
      network: network,
      power: power,
      processes: []
    )
  }

  func sampleProcesses() -> [ProcessRow] {
    let now = ProcessInfo.processInfo.systemUptime
    let processElapsed = max(0.001, now - previousProcessTime)
    let processNetworkCounters = readProcessNetworkCounters()
    let processes = readProcesses(
      elapsed: processElapsed,
      networkCounters: processNetworkCounters
    )
    previousProcessTime = now
    return processes
  }

  private func readCPUTicks() -> CPUTicks {
    var cpuCount: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(
      mach_host_self(),
      PROCESSOR_CPU_LOAD_INFO,
      &cpuCount,
      &cpuInfo,
      &infoCount
    )
    guard result == KERN_SUCCESS, let cpuInfo else {
      return CPUTicks(user: 0, system: 0, idle: 0)
    }
    defer {
      let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
      vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
    }

    let values = UnsafeBufferPointer(start: cpuInfo, count: Int(infoCount))
    var ticks = CPUTicks(user: 0, system: 0, idle: 0)
    for cpu in 0..<Int(cpuCount) {
      let base = cpu * Int(CPU_STATE_MAX)
      ticks.user += UInt64(values[base + Int(CPU_STATE_USER)])
      ticks.user += UInt64(values[base + Int(CPU_STATE_NICE)])
      ticks.system += UInt64(values[base + Int(CPU_STATE_SYSTEM)])
      ticks.idle += UInt64(values[base + Int(CPU_STATE_IDLE)])
    }
    return ticks
  }

  private func calculateCPU(
    current: CPUTicks,
    previous: CPUTicks?,
    temperature: TemperatureUsage
  ) -> CPUUsage {
    guard let previous else {
      return CPUUsage(total: 0, user: 0, system: 0, temperature: temperature)
    }
    let user = current.user >= previous.user ? current.user - previous.user : 0
    let system = current.system >= previous.system ? current.system - previous.system : 0
    let idle = current.idle >= previous.idle ? current.idle - previous.idle : 0
    let total = max(1, user + system + idle)
    let userPercent = Double(user) / Double(total) * 100
    let systemPercent = Double(system) / Double(total) * 100
    return CPUUsage(
      total: userPercent + systemPercent,
      user: userPercent,
      system: systemPercent,
      temperature: temperature
    )
  }

  private func readMemoryUsage() -> MemoryUsage {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return MemoryUsage(used: 0, available: 0, total: ProcessInfo.processInfo.physicalMemory)
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let availablePages =
      UInt64(statistics.free_count)
      + UInt64(statistics.inactive_count)
      + UInt64(statistics.speculative_count)
    let total = ProcessInfo.processInfo.physicalMemory
    let available = min(total, availablePages * UInt64(pageSize))
    return MemoryUsage(used: total - available, available: available, total: total)
  }

  private func readDiskCapacity() -> (used: UInt64, available: UInt64, total: UInt64) {
    let keys: Set<URLResourceKey> = [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
    ]
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else {
      return (0, 0, 0)
    }
    let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
    let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
    return (total - min(total, available), available, total)
  }

  private func readDiskCounters() -> ByteCounters {
    var iterator: io_iterator_t = 0
    guard
      let matching = IOServiceMatching("IOBlockStorageDriver"),
      IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else {
      return ByteCounters(read: 0, written: 0)
    }
    defer { IOObjectRelease(iterator) }

    var counters = ByteCounters(read: 0, written: 0)
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let value = IORegistryEntryCreateCFProperty(
        service,
        "Statistics" as CFString,
        kCFAllocatorDefault,
        0
      )?.takeRetainedValue(),
        let statistics = value as? [String: Any]
      {
        counters.read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        counters.written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
      }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return counters
  }

  private func readNetworkCounters() -> ByteCounters {
    var addressList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
      return ByteCounters(read: 0, written: 0)
    }
    defer { freeifaddrs(addressList) }

    var counters = ByteCounters(read: 0, written: 0)
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let address = pointer?.pointee {
      defer { pointer = address.ifa_next }
      guard address.ifa_addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
      let flags = Int32(address.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      let name = String(cString: address.ifa_name)
      guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun") else {
        continue
      }
      guard let rawData = address.ifa_data else { continue }
      let data = rawData.assumingMemoryBound(to: if_data.self).pointee
      counters.read += UInt64(data.ifi_ibytes)
      counters.written += UInt64(data.ifi_obytes)
    }
    return counters
  }

  private func readProcesses(
    elapsed: TimeInterval,
    networkCounters: [Int32: ByteCounters]
  ) -> [ProcessRow] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,user=,state=,comm="]
    process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return []
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      return []
    }

    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    var rows: [ProcessRow] = []
    var currentDisk: [Int32: ByteCounters] = [:]
    var currentNetwork: [Int32: ByteCounters] = [:]
    var currentPaths: [Int32: (command: String, path: String)] = [:]

    for line in text.split(separator: "\n") {
      let fields = line.split(
        maxSplits: 7,
        omittingEmptySubsequences: true,
        whereSeparator: { $0 == " " || $0 == "\t" }
      )
      guard
        fields.count == 8,
        let pid = Int32(fields[0]),
        pid != ownPID,
        let parentPID = Int32(fields[1]),
        let cpu = Double(fields[2]),
        let residentKilobytes = UInt64(fields[3])
      else {
        continue
      }
      let command = String(fields[7])
      let executablePath: String
      if let cached = cachedProcessPaths[pid], cached.command == command {
        executablePath = cached.path
      } else {
        executablePath = readExecutablePath(pid: pid) ?? command
      }
      currentPaths[pid] = (command, executablePath)
      let filename = URL(fileURLWithPath: executablePath).lastPathComponent
      let software = processClassifier.software(
        executablePath: executablePath,
        command: command
      )
      let disk = readProcessDiskCounters(pid: pid)
      if let disk {
        currentDisk[pid] = disk
      }
      let network = networkCounters[pid]
      if let network {
        currentNetwork[pid] = network
      }

      rows.append(
        ProcessRow(
          pid: pid,
          parentPID: parentPID,
          name: filename.isEmpty ? command : filename,
          user: String(fields[5]),
          state: String(fields[6]),
          executablePath: executablePath,
          cpuPercent: max(0, cpu),
          memoryBytes: residentKilobytes * 1_024,
          diskReadRate: rate(
            current: disk?.read ?? 0,
            previous: disk == nil ? nil : previousProcessDisk[pid]?.read,
            elapsed: elapsed
          ),
          diskWriteRate: rate(
            current: disk?.written ?? 0,
            previous: disk == nil ? nil : previousProcessDisk[pid]?.written,
            elapsed: elapsed
          ),
          diskReadTotal: disk?.read ?? 0,
          diskWriteTotal: disk?.written ?? 0,
          networkDownloadRate: rate(
            current: network?.read ?? 0,
            previous: network == nil ? nil : previousProcessNetwork[pid]?.read,
            elapsed: elapsed
          ),
          networkUploadRate: rate(
            current: network?.written ?? 0,
            previous: network == nil ? nil : previousProcessNetwork[pid]?.written,
            elapsed: elapsed
          ),
          networkDownloadTotal: network?.read ?? 0,
          networkUploadTotal: network?.written ?? 0,
          threadCount: readThreadCount(pid: pid),
          runtime: parseElapsed(String(fields[4])),
          software: software
        ))
    }

    previousProcessDisk = currentDisk
    previousProcessNetwork = currentNetwork
    cachedProcessPaths = currentPaths
    return inheritInstalledSoftwareForUnidentifiedChildren(rows)
  }

  private func inheritInstalledSoftwareForUnidentifiedChildren(_ rows: [ProcessRow])
    -> [ProcessRow]
  {
    let rowsByPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })

    func installedAncestor(for process: ProcessRow) -> SoftwareIdentity? {
      guard process.software.origin == .unknown else { return nil }
      var parentPID = process.parentPID
      var visited = Set<Int32>()
      for _ in 0..<6 {
        guard visited.insert(parentPID).inserted, let parent = rowsByPID[parentPID] else {
          return nil
        }
        if parent.software.origin == .installedSoftware {
          return parent.software
        }
        guard parent.software.origin == .unknown else { return nil }
        parentPID = parent.parentPID
      }
      return nil
    }

    return rows.map { process in
      guard let inherited = installedAncestor(for: process) else { return process }
      return process.replacing(software: inherited)
    }
  }

  private func readExecutablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func readProcessDiskCounters(pid: Int32) -> ByteCounters? {
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      rawProcPIDRUsage(pid, Int32(RUSAGE_INFO_V2), UnsafeMutableRawPointer(pointer))
    }
    guard result == 0 else { return nil }
    return ByteCounters(
      read: usage.ri_diskio_bytesread,
      written: usage.ri_diskio_byteswritten
    )
  }

  private func readProcessNetworkCounters() -> [Int32: ByteCounters] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = [
      "-P", "-L", "1", "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out",
    ]
    process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return [:]
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      return [:]
    }

    var counters: [Int32: ByteCounters] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: ",", omittingEmptySubsequences: false)
      guard fields.count >= 3 else { continue }
      let identity = fields[0]
      guard let separator = identity.lastIndex(of: "."),
        let pid = Int32(identity[identity.index(after: separator)...]),
        let downloaded = UInt64(fields[1]),
        let uploaded = UInt64(fields[2])
      else {
        continue
      }
      counters[pid] = ByteCounters(read: downloaded, written: uploaded)
    }
    return counters
  }

  private func readTemperatureUsage() -> TemperatureUsage {
    let framework = "/System/Library/Frameworks/IOKit.framework/IOKit"
    guard let handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL) else {
      return .unavailable
    }
    defer { dlclose(handle) }

    guard
      let create = loadSymbol(handle, "IOHIDEventSystemClientCreate", as: HIDClientCreate.self),
      let setMatching = loadSymbol(
        handle,
        "IOHIDEventSystemClientSetMatching",
        as: HIDClientSetMatching.self
      ),
      let copyServices = loadSymbol(
        handle,
        "IOHIDEventSystemClientCopyServices",
        as: HIDClientCopyServices.self
      ),
      let copyProperty = loadSymbol(
        handle,
        "IOHIDServiceClientCopyProperty",
        as: HIDServiceCopyProperty.self
      ),
      let copyEvent = loadSymbol(
        handle,
        "IOHIDServiceClientCopyEvent",
        as: HIDServiceCopyEvent.self
      ),
      let getFloatValue = loadSymbol(
        handle,
        "IOHIDEventGetFloatValue",
        as: HIDEventGetFloatValue.self
      )
    else {
      return .unavailable
    }

    let matching: NSDictionary = [
      "PrimaryUsagePage": NSNumber(value: 0xFF00),
      "PrimaryUsage": NSNumber(value: 0x0005),
    ]
    guard let system = create(nil) else { return .unavailable }
    defer { Unmanaged<CFTypeRef>.fromOpaque(system).release() }
    setMatching(system, Unmanaged.passUnretained(matching).toOpaque())

    guard let servicesPointer = copyServices(system) else { return .unavailable }
    let services = Unmanaged<CFArray>.fromOpaque(servicesPointer).takeRetainedValue()
    let productKey: NSString = "Product"
    let productKeyPointer = Unmanaged.passUnretained(productKey).toOpaque()
    var sensors: [(String, Double)] = []

    for index in 0..<CFArrayGetCount(services) {
      guard let service = CFArrayGetValueAtIndex(services, index) else { continue }
      let name: String
      if let namePointer = copyProperty(service, productKeyPointer) {
        let property = Unmanaged<CFTypeRef>.fromOpaque(namePointer).takeRetainedValue()
        name = property as? String ?? "Unknown sensor"
      } else {
        name = "Unknown sensor"
      }

      let temperatureEvent: Int64 = 15
      guard let event = copyEvent(service, temperatureEvent, 0, 0) else { continue }
      let value = getFloatValue(event, temperatureEvent << 16)
      Unmanaged<CFTypeRef>.fromOpaque(event).release()
      if value > 0, value <= 150 {
        sensors.append((name, value))
      }
    }

    return summarizeTemperatures(sensors)
  }

  private func summarizeTemperatures(_ sensors: [(String, Double)]) -> TemperatureUsage {
    var soc = sensors.filter { $0.0.localizedCaseInsensitiveContains("tdie") }.map(\.1)
    let battery = sensors.filter { $0.0.localizedCaseInsensitiveContains("battery") }.map(\.1)
    let storage = sensors.filter { $0.0.localizedCaseInsensitiveContains("nand") }.map(\.1)
    if soc.isEmpty {
      soc = sensors.filter { sensor in
        let name = sensor.0.lowercased()
        return !name.contains("battery") && !name.contains("nand") && !name.contains("tcal")
      }.map(\.1)
    }
    let socTemperature = soc.max()
    let status: ThermalStatus
    switch socTemperature {
    case .some(let value) where value >= 95:
      status = .hot
    case .some(let value) where value >= 80:
      status = .warm
    case .some:
      status = .normal
    case .none:
      status = .unavailable
    }
    return TemperatureUsage(
      socCelsius: socTemperature,
      batteryCelsius: battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count),
      storageCelsius: storage.max(),
      status: status
    )
  }

  private func loadSymbol<T>(
    _ handle: UnsafeMutableRawPointer,
    _ name: String,
    as type: T.Type
  ) -> T? {
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
  }

  private func readThreadCount(pid: Int32) -> Int {
    var information = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = withUnsafeMutablePointer(to: &information) { pointer in
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
    }
    return result == size ? max(0, Int(information.pti_threadnum)) : 0
  }

  private func parseElapsed(_ value: String) -> TimeInterval {
    let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
    let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
    let clock = dayParts.last?.split(separator: ":").compactMap { Double($0) } ?? []
    switch clock.count {
    case 3:
      return days * 86_400 + clock[0] * 3_600 + clock[1] * 60 + clock[2]
    case 2:
      return days * 86_400 + clock[0] * 60 + clock[1]
    case 1:
      return days * 86_400 + clock[0]
    default:
      return days * 86_400
    }
  }

  private func rate(current: UInt64, previous: UInt64?, elapsed: TimeInterval) -> Double {
    guard let previous, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }
}
