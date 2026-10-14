import Foundation
import Testing

@testable import MacScopeNative

@Suite("Maintenance operation isolation", .timeLimit(.minutes(1)))
@MainActor
struct MaintenanceStoreTests {
  @Test("A scan replaced before it starts does not run or cancel its replacement")
  func replacementBeforeStart() async throws {
    let store = MaintenanceStore()
    let oldScan = ControlledMaintenanceScan()
    let replacement = ControlledMaintenanceScan()
    var oldApplied = false
    let oldTask = store.beginScan(tool: .junk, title: "Old scan") { progress in
      try await oldScan.run(progress: progress)
    } apply: { _ in
      oldApplied = true
    }
    let replacementTask = store.beginScan(tool: .largeFiles, title: "Replacement") { progress in
      try await replacement.run(progress: progress)
    } apply: { _ in }

    await oldTask.value
    await replacement.waitUntilStarted()
    #expect(!oldScan.didStart)
    #expect(!oldApplied)
    #expect(store.activity?.tool == .largeFiles)
    #expect(store.activity?.phase == .scanning)
    #expect(store.isBusy)

    replacement.finish(.success(ScanResult(values: [1], issues: [], scannedCount: 1)))
    await replacementTask.value
    #expect(store.activity == nil)
    #expect(store.scannedTools == [.largeFiles])
  }

  @Test(
    "Late progress and completion from an old scan cannot change the replacement",
    arguments: ["cancellation", "failure", "success"], [MaintenanceTool.junk, .largeFiles]
  )
  func replacementDuringScan(completion: String, replacementTool: MaintenanceTool) async throws {
    let store = MaintenanceStore()
    let oldScan = ControlledMaintenanceScan()
    let replacement = ControlledMaintenanceScan()
    var oldApplied = false
    var replacementValues: [Int] = []
    let oldTask = store.beginScan(tool: .junk, title: "Old scan") { progress in
      try await oldScan.run(progress: progress)
    } apply: { _ in
      oldApplied = true
    }
    await oldScan.waitUntilStarted()

    let replacementTask = store.beginScan(tool: replacementTool, title: "Replacement") { progress in
      try await replacement.run(progress: progress)
    } apply: { result in
      replacementValues = result.values
    }
    await replacement.waitUntilStarted()
    let replacementID = try #require(store.activity?.id)
    let preparingPath = store.activity?.currentPath

    await oldScan.report(count: 999, path: "/stale-progress")
    #expect(store.activity?.currentPath == preparingPath)
    #expect(store.activity?.completed == 0)
    await replacement.report(count: 7, path: "/replacement-progress")
    #expect(store.activity?.currentPath == "/replacement-progress")
    #expect(store.activity?.completed == 7)

    switch completion {
    case "cancellation":
      oldScan.finish(.failure(CancellationError()))
    case "failure":
      oldScan.finish(.failure(CocoaError(.fileReadUnknown)))
    default:
      oldScan.finish(.success(ScanResult(values: [999], issues: [], scannedCount: 999)))
    }
    await oldTask.value
    #expect(store.activity?.id == replacementID)
    #expect(store.activity?.phase == .scanning)
    #expect(store.activity?.currentPath == "/replacement-progress")
    #expect(store.isBusy)
    #expect(!oldApplied)
    #expect(store.scannedTools.isEmpty)
    #expect(store.issuesByTool[.junk] == nil)

    let issue = ScanIssue(
      url: URL(fileURLWithPath: "/unavailable-folder"),
      kind: .unavailable,
      detail: "Folder unavailable"
    )
    replacement.finish(.success(ScanResult(values: [42], issues: [issue], scannedCount: 9)))
    await replacementTask.value
    #expect(replacementValues == [42])
    #expect(store.scannedTools == [replacementTool])
    #expect(store.activity?.id == replacementID)
    #expect(store.activity?.phase == .completed)
    #expect(store.activity?.completed == 9)
    #expect(store.activity?.scanIssues.map(\.id) == [issue.id])
    #expect(!store.isBusy)
  }

  @Test("A late error cannot restore a dismissed cancelled activity")
  func errorAfterDismissal() async {
    let store = MaintenanceStore()
    let scan = ControlledMaintenanceScan()
    var applied = false
    let task = store.beginScan(tool: .junk, title: "Scan") { progress in
      try await scan.run(progress: progress)
    } apply: { _ in
      applied = true
    }
    await scan.waitUntilStarted()
    store.cancelCurrentOperation()
    #expect(store.activity?.phase == .cancelled)
    store.dismissActivity()

    await scan.report(count: 999, path: "/stale-progress")
    scan.finish(.failure(CocoaError(.fileReadUnknown)))
    await task.value
    #expect(store.activity == nil)
    #expect(store.issuesByTool[.junk] == nil)
    #expect(!applied)
    #expect(!store.isBusy)
  }
}
