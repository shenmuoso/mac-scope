import Foundation

@testable import MacScopeNative

@MainActor
final class ControlledMaintenanceScan {
  private enum Action {
    case progress(ScanProgress)
    case finish(Result<ScanResult<Int>, any Error>)
  }

  private(set) var didStart = false
  private var actionContinuation: CheckedContinuation<Action, Never>?
  private var progressContinuation: CheckedContinuation<Void, Never>?
  private var startContinuation: CheckedContinuation<Void, Never>?

  func run(progress: MaintenanceService.ScanReporter) async throws -> ScanResult<Int> {
    // Checked continuations let tests deliver callbacks after cancellation.
    while true {
      let action = await withCheckedContinuation { continuation in
        actionContinuation = continuation
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
      }
      switch action {
      case .progress(let update):
        await progress(update)
        progressContinuation?.resume()
        progressContinuation = nil
      case .finish(let result):
        return try result.get()
      }
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { startContinuation = $0 }
  }

  func report(count: Int, path: String) async {
    await withCheckedContinuation { continuation in
      progressContinuation = continuation
      send(.progress(ScanProgress(scannedCount: count, currentPath: path)))
    }
  }

  func finish(_ result: Result<ScanResult<Int>, any Error>) {
    send(.finish(result))
  }

  private func send(_ action: Action) {
    guard let continuation = actionContinuation else {
      preconditionFailure("Wait for the scan to start before sending an action")
    }
    actionContinuation = nil
    continuation.resume(returning: action)
  }
}
