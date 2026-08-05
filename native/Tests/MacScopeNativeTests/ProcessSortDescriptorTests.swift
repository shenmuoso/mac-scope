import Foundation
import Testing

@testable import MacScopeNative

@Suite("Process table sorting")
struct ProcessSortDescriptorTests {
  @Test("Metric columns default to descending order")
  func selectsConventionalDirections() {
    var sort = ProcessSortDescriptor.initial

    sort.select(.memory)
    #expect(sort == ProcessSortDescriptor(field: .memory, direction: .descending))

    sort.select(.memory)
    #expect(sort == ProcessSortDescriptor(field: .memory, direction: .ascending))

    sort.select(.name)
    #expect(sort == ProcessSortDescriptor(field: .name, direction: .ascending))
  }

  @Test("Memory ties use a deterministic name and PID order")
  func stabilizesMemoryTies() {
    let processes = [
      process(pid: 42, name: "Zulu", memory: 400),
      process(pid: 19, name: "Alpha", memory: 200),
      process(pid: 7, name: "Alpha", memory: 200),
    ]
    let sort = ProcessSortDescriptor(field: .memory, direction: .descending)

    #expect(sort.sorted(processes: processes).map(\.pid) == [42, 7, 19])
    #expect(sort.sorted(processes: Array(processes.reversed())).map(\.pid) == [42, 7, 19])
  }

  @Test("Non-finite metric values still receive a stable order")
  func stabilizesNonFiniteMetrics() {
    let processes = [
      process(pid: 30, name: "Beta", cpu: .nan),
      process(pid: 20, name: "Alpha", cpu: .nan),
      process(pid: 10, name: "Alpha", cpu: .nan),
      process(pid: 40, name: "Gamma", cpu: 20),
    ]
    let sort = ProcessSortDescriptor(field: .cpu, direction: .descending)

    #expect(sort.sorted(processes: processes).map(\.pid) == [40, 10, 20, 30])
  }

  private func process(
    pid: Int32,
    name: String,
    cpu: Double = 0,
    memory: UInt64 = 0
  ) -> ProcessRow {
    let software = SoftwareIdentity(
      id: "process:\(pid)",
      name: name,
      bundleIdentifier: nil,
      bundleURL: nil,
      origin: .unknown
    )
    return ProcessRow(
      pid: pid,
      parentPID: 1,
      name: name,
      user: "example",
      state: "S",
      executablePath: "/usr/bin/\(name)",
      cpuPercent: cpu,
      memoryBytes: memory,
      diskReadRate: 0,
      diskWriteRate: 0,
      diskReadTotal: 0,
      diskWriteTotal: 0,
      networkDownloadRate: 0,
      networkUploadRate: 0,
      networkDownloadTotal: 0,
      networkUploadTotal: 0,
      threadCount: 1,
      runtime: 60,
      software: software
    )
  }
}
