import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class StartupItemsStore: ObservableObject {
  @Published private(set) var loginItems: [SystemLoginItem] = []
  @Published private(set) var backgroundItems: [StartupItem] = []
  @Published private(set) var loginItemsAccess: LoginItemsAccessState = .available
  @Published private(set) var scanIssues: [String] = []
  @Published private(set) var isScanning = false
  @Published private(set) var operationItemID: String?
  @Published private(set) var hasScanned = false
  @Published private(set) var operationError: String?
  @Published private(set) var tableIdentity = UUID()

  private let service = StartupItemService()
  private var task: Task<Void, Never>?

  var attentionLoginItems: [SystemLoginItem] {
    loginItems.filter { $0.residueState != .none }
  }

  var attentionBackgroundItems: [StartupItem] {
    backgroundItems.filter { $0.residueState != .none || $0.parseIssue != nil }
  }

  func scan() {
    guard !isScanning, operationItemID == nil else { return }
    task?.cancel()
    NSApp.activate(ignoringOtherApps: true)
    isScanning = true
    operationError = nil
    task = Task { [weak self, service] in
      let result = await service.scan()
      guard let self, !Task.isCancelled else { return }
      loginItems = result.loginItems
      backgroundItems = result.backgroundItems
      loginItemsAccess = result.loginItemsAccess
      scanIssues = result.issues
      tableIdentity = UUID()
      hasScanned = true
      isScanning = false
      task = nil
    }
  }

  func chooseLoginItemApplication() {
    guard operationItemID == nil, !isScanning else { return }
    let panel = NSOpenPanel()
    panel.title = String(localized: "Add Login Item")
    panel.message = String(localized: "Choose an application to open automatically when you log in.")
    panel.prompt = String(localized: "Add")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let path = url.standardizedFileURL.path
    if loginItems.contains(where: { $0.targetURL?.path == path }) {
      operationError = String(localized: "This application is already in Login Items.")
      return
    }
    runOperation(id: "add-login:\(path)") { [service] in
      await service.addLoginItem(at: url)
    }
  }

  func removeLoginItem(_ item: SystemLoginItem) {
    runOperation(id: item.id) { [service] in
      await service.removeLoginItem(item)
    }
  }

  func setStartupAllowed(_ isAllowed: Bool, for item: StartupItem) {
    runOperation(id: item.id) { [service] in
      await service.setStartupAllowed(isAllowed, for: item)
    }
  }

  func removeBackgroundItem(_ item: StartupItem) {
    runOperation(id: item.id) { [service] in
      await service.remove(item)
    }
  }

  func reveal(_ item: StartupItem) {
    NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
  }

  func openBackgroundItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func openAutomationSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  func clearError() {
    operationError = nil
  }

  private func runOperation(
    id: String,
    operation: @escaping @Sendable () async -> StartupItemOperationResult
  ) {
    guard operationItemID == nil, !isScanning else { return }
    NSApp.activate(ignoringOtherApps: true)
    operationItemID = id
    operationError = nil
    task = Task { [weak self] in
      let result = await operation()
      guard let self, !Task.isCancelled else { return }
      operationItemID = nil
      handle(result)
      if case .success = result {
        scan()
      }
    }
  }

  private func handle(_ result: StartupItemOperationResult) {
    switch result {
    case .success, .cancelled:
      break
    case .failure(let message):
      operationError = message
    }
  }
}
