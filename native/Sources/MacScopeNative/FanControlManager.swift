import CryptoKit
import Darwin
import Foundation

enum FanControlSessionState: Equatable, Sendable {
  case idle
  case authorizing
  case starting
  case active(endsAt: Date, maximumRPM: Int?)
  case stopping
  case recoveryNeeded(String?)
  case failed(String)
}

enum FanControlCapability {
  static func supports(_ cooling: CoolingUsage) -> Bool {
    cooling.state == .available
      && !cooling.fans.isEmpty
      && cooling.fans.allSatisfy { fan in
        guard let maximum = fan.maximumRPM, let target = fan.targetRPM else { return false }
        return maximum.isFinite
          && target.isFinite
          && maximum >= 1_000
          && maximum <= 30_000
          && target >= 0
          && target <= 30_000
          && target <= maximum
      }
  }
}

@MainActor
final class FanControlManager: ObservableObject {
  @Published private(set) var state: FanControlSessionState
  @Published private(set) var remainingSeconds: Int?
  @Published private(set) var lastMessage: String?
  @Published var selectedDurationMinutes = 30

  private struct HelperStatus: Decodable {
    let state: String
    let message: String?
    let startedAt: TimeInterval?
    let endsAt: TimeInterval?
    let maximumRPM: Int?
    let helperPID: Int32
    let updatedAt: TimeInterval
  }

  private enum Key {
    static let recoveryNeeded = "native.fanControlRecoveryNeeded"
    static let sessionPath = "native.fanControlSessionPath"
  }

  private enum Mode: String, Sendable {
    case maximum
    case restore
  }

  private let defaults: UserDefaults
  private let fileManager: FileManager
  private var sessionURL: URL?
  private var monitorTask: Task<Void, Never>?
  private var authorizationTask: Task<Void, Never>?
  private var helperLaunchCompletedAt: Date?
  private var livenessGraceUntil: Date?
  private var writesHeartbeat = true

  init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
    self.defaults = defaults
    self.fileManager = fileManager
    state = defaults.bool(forKey: Key.recoveryNeeded) ? .recoveryNeeded(nil) : .idle
    reconcilePersistedSession()
  }

  deinit {
    monitorTask?.cancel()
    authorizationTask?.cancel()
  }

  var isBusy: Bool {
    switch state {
    case .authorizing, .starting, .active, .stopping: true
    case .idle, .recoveryNeeded, .failed: false
    }
  }

  func canStart(with cooling: CoolingUsage) -> Bool {
    FanControlCapability.supports(cooling)
  }

  func startMaximumCooling(with cooling: CoolingUsage) {
    guard
      state == .idle,
      canStart(with: cooling),
      [15, 30, 60].contains(selectedDurationMinutes)
    else { return }
    launch(mode: .maximum, duration: TimeInterval(selectedDurationMinutes * 60))
  }

  func restoreSystemControl() {
    guard case .recoveryNeeded = state else { return }
    if sessionURL != nil {
      requestStop()
      finishMonitoringSession(removeFiles: true)
    } else {
      removePersistedSessionDirectory()
    }
    launch(mode: .restore, duration: 900)
  }

  func dismissFailure() {
    guard case .failed = state else { return }
    state = .idle
  }

  func stopMaximumCooling() {
    guard case .active = state, let sessionURL else { return }
    state = .stopping
    do {
      try Data().write(to: sessionURL.appendingPathComponent("stop"), options: .atomic)
    } catch {
      defaults.set(true, forKey: Key.recoveryNeeded)
      state = .recoveryNeeded(error.localizedDescription)
      remainingSeconds = nil
      finishMonitoringSession(removeFiles: false)
    }
  }

  func prepareForApplicationExit() {
    requestStop()
  }

  func prepareForSleep() {
    if case .active = state {
      state = .stopping
    }
    requestStop()
  }

  func resumeAfterWake() {
    if let sessionURL {
      livenessGraceUntil = Date().addingTimeInterval(12)
      consumeStatus(in: sessionURL, checkLiveness: false)
      if self.sessionURL != nil {
        requestStop()
        state = .stopping
        if monitorTask == nil {
          startMonitoringSession(writeHeartbeat: writesHeartbeat)
        }
      }
    } else if defaults.bool(forKey: Key.recoveryNeeded) {
      reconcilePersistedSession()
    }
  }

  private func requestStop() {
    guard let sessionURL else { return }
    try? Data().write(to: sessionURL.appendingPathComponent("stop"), options: .atomic)
  }

  private func launch(mode: Mode, duration: TimeInterval) {
    guard authorizationTask == nil, let helperURL = bundledHelperURL() else {
      handlePreparationFailure(
        "The fan-control helper is missing from this MacScope build.",
        mode: mode
      )
      return
    }

    let sessionURL: URL
    do {
      sessionURL = try createSessionDirectory()
      try writeHeartbeat(in: sessionURL)
    } catch {
      handlePreparationFailure(error.localizedDescription, mode: mode)
      return
    }

    guard let expectedHash = sha256(of: helperURL) else {
      handlePreparationFailure("The fan-control helper could not be verified.", mode: mode)
      try? fileManager.removeItem(at: sessionURL)
      return
    }

    self.sessionURL = sessionURL
    defaults.set(sessionURL.path, forKey: Key.sessionPath)
    helperLaunchCompletedAt = nil
    livenessGraceUntil = Date().addingTimeInterval(90)
    remainingSeconds = nil
    lastMessage = nil
    defaults.set(true, forKey: Key.recoveryNeeded)
    state = .authorizing
    startMonitoringSession(writeHeartbeat: true)

    let ownerPID = getpid()
    let ownerUID = getuid()
    authorizationTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        SystemPermission.launchFanControlHelperWithAdministratorAuthorization(
          helperURL: helperURL,
          expectedSHA256: expectedHash,
          mode: mode.rawValue,
          duration: duration,
          ownerPID: ownerPID,
          ownerUID: ownerUID,
          sessionURL: sessionURL
        )
      }.value
      guard let self else { return }
      self.authorizationTask = nil
      switch result {
      case .success:
        if self.sessionURL == sessionURL {
          self.helperLaunchCompletedAt = Date()
          if self.state == .authorizing {
            self.state = .starting
          }
        }
      case .cancelled:
        self.handleAuthorizationFailure(nil, mode: mode, cancelled: true)
      case .failure(let message):
        self.handleAuthorizationFailure(message, mode: mode, cancelled: false)
      }
    }
  }

  private func startMonitoringSession(writeHeartbeat: Bool) {
    monitorTask?.cancel()
    writesHeartbeat = writeHeartbeat
    monitorTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        if let sessionURL = self.sessionURL {
          if self.writesHeartbeat {
            try? self.writeHeartbeat(in: sessionURL)
          }
          self.consumeStatus(in: sessionURL)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func consumeStatus(in sessionURL: URL, checkLiveness: Bool = true) {
    if let status = readStatus(in: sessionURL) {
      let updatedAt = Date(timeIntervalSince1970: status.updatedAt)
      let stopRequested = fileManager.fileExists(
        atPath: sessionURL.appendingPathComponent("stop").path
      )
      let shouldCheckLiveness =
        checkLiveness && (livenessGraceUntil.map { Date() >= $0 } ?? true)
      switch status.state {
      case "starting":
        state = stopRequested ? .stopping : .starting
        if shouldCheckLiveness
          && (Date().timeIntervalSince(updatedAt) > 90 || !processExists(status.helperPID))
        {
          state = .recoveryNeeded("The fan-control helper stopped responding.")
          finishMonitoringSession(removeFiles: false)
        }
      case "active":
        let endsAt = Date(timeIntervalSince1970: status.endsAt ?? Date().timeIntervalSince1970)
        state = stopRequested ? .stopping : .active(endsAt: endsAt, maximumRPM: status.maximumRPM)
        remainingSeconds = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
        if Date().timeIntervalSince(updatedAt) <= 2 {
          livenessGraceUntil = nil
        }
        if shouldCheckLiveness
          && (Date().timeIntervalSince(updatedAt) > 7 || !processExists(status.helperPID))
        {
          state = .recoveryNeeded("The fan-control helper stopped responding.")
          remainingSeconds = nil
          finishMonitoringSession(removeFiles: false)
        }
      case "restored":
        defaults.set(false, forKey: Key.recoveryNeeded)
        lastMessage = status.message
        state = .idle
        remainingSeconds = nil
        finishMonitoringSession(removeFiles: true)
      case "failed":
        state = .recoveryNeeded(status.message)
        remainingSeconds = nil
        finishMonitoringSession(removeFiles: false)
      default:
        break
      }
      return
    }

    if
      let helperLaunchCompletedAt,
      Date().timeIntervalSince(helperLaunchCompletedAt) > 15,
      state == .starting
    {
      state = .recoveryNeeded("The fan-control helper did not report a verified state.")
      finishMonitoringSession(removeFiles: false)
    } else if
      case .stopping = state,
      let livenessGraceUntil,
      Date() >= livenessGraceUntil
    {
      state = .recoveryNeeded("The fan-control helper did not confirm automatic control.")
      finishMonitoringSession(removeFiles: false)
    }
  }

  private func createSessionDirectory() throws -> URL {
    let root = sessionsRootURL
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let session = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: session,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
    return session
  }

  private func writeHeartbeat(in sessionURL: URL) throws {
    let data = Data(String(Date().timeIntervalSince1970).utf8)
    try data.write(to: sessionURL.appendingPathComponent("heartbeat"), options: .atomic)
  }

  private func bundledHelperURL() -> URL? {
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/Helpers/MacScopeFanControlHelper")
    return fileManager.isExecutableFile(atPath: url.path) ? url : nil
  }

  private func sha256(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func processExists(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  private func finishMonitoringSession(removeFiles: Bool) {
    monitorTask?.cancel()
    monitorTask = nil
    helperLaunchCompletedAt = nil
    livenessGraceUntil = nil
    if removeFiles, let sessionURL {
      try? fileManager.removeItem(at: sessionURL)
    }
    if removeFiles {
      defaults.removeObject(forKey: Key.sessionPath)
    }
    sessionURL = nil
  }

  private var sessionsRootURL: URL {
    fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.shenmuoso.macscope/FanControl", isDirectory: true)
  }

  private func removePersistedSessionDirectory() {
    defer { defaults.removeObject(forKey: Key.sessionPath) }
    guard let path = defaults.string(forKey: Key.sessionPath) else { return }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let rootPath = sessionsRootURL.standardizedFileURL.path + "/"
    guard url.path.hasPrefix(rootPath) else { return }
    try? fileManager.removeItem(at: url)
  }

  private func handlePreparationFailure(_ message: String, mode: Mode) {
    if mode == .restore || defaults.bool(forKey: Key.recoveryNeeded) {
      defaults.set(true, forKey: Key.recoveryNeeded)
      state = .recoveryNeeded(message)
    } else {
      defaults.set(false, forKey: Key.recoveryNeeded)
      defaults.removeObject(forKey: Key.sessionPath)
      state = .failed(message)
    }
  }

  private func handleAuthorizationFailure(_ message: String?, mode: Mode, cancelled: Bool) {
    if mode == .restore {
      defaults.set(true, forKey: Key.recoveryNeeded)
      state = .recoveryNeeded(
        message ?? (cancelled ? "Administrator authorization was cancelled." : nil)
      )
    } else {
      defaults.set(false, forKey: Key.recoveryNeeded)
      state = cancelled ? .idle : .failed(message ?? "Administrator authorization failed.")
    }
    finishMonitoringSession(removeFiles: true)
  }

  private func reconcilePersistedSession() {
    guard defaults.bool(forKey: Key.recoveryNeeded) else {
      defaults.removeObject(forKey: Key.sessionPath)
      return
    }
    guard
      let path = defaults.string(forKey: Key.sessionPath),
      !path.isEmpty
    else {
      state = .recoveryNeeded(nil)
      return
    }

    let persistedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let rootPath = sessionsRootURL.standardizedFileURL.path + "/"
    guard persistedURL.path.hasPrefix(rootPath) else {
      defaults.removeObject(forKey: Key.sessionPath)
      state = .recoveryNeeded(nil)
      return
    }
    guard fileManager.fileExists(atPath: persistedURL.path) else {
      defaults.removeObject(forKey: Key.sessionPath)
      state = .recoveryNeeded(nil)
      return
    }

    guard let status = readStatus(in: persistedURL) else {
      state = .recoveryNeeded("Checking whether the previous fan-control session was restored.")
      return
    }

    sessionURL = persistedURL
    if status.state == "restored" {
      consumeStatus(in: persistedURL, checkLiveness: false)
    } else if status.state == "active" || status.state == "starting" {
      livenessGraceUntil = Date().addingTimeInterval(12)
      requestStop()
      state = .stopping
      startMonitoringSession(writeHeartbeat: false)
    } else {
      state = .recoveryNeeded(status.message)
      finishMonitoringSession(removeFiles: false)
    }
  }

  private func readStatus(in sessionURL: URL) -> HelperStatus? {
    let statusURL = sessionURL.appendingPathComponent("status.json")
    guard let data = try? Data(contentsOf: statusURL) else { return nil }
    return try? JSONDecoder().decode(HelperStatus.self, from: data)
  }
}
