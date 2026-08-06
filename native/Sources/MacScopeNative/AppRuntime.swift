import AppKit
import Combine

@MainActor
final class AppRuntime: ObservableObject {
  let monitor: SystemMonitor
  let settings: AppSettings
  let maintenance: MaintenanceStore
  let startupItems: StartupItemsStore
  let navigation: AppNavigation
  let updateChecker: UpdateChecker

  private var menuBarController: MenuBarController?
  private var openMainWindowHandler: (() -> Void)?
  private var hasStarted = false
  private var mainWindowIsClosing = false
  private var cancellables: Set<AnyCancellable> = []

  init() {
    monitor = SystemMonitor()
    settings = AppSettings()
    maintenance = MaintenanceStore()
    startupItems = StartupItemsStore()
    navigation = AppNavigation()
    updateChecker = UpdateChecker()

    let sceneSettingsChanges: [AnyPublisher<Void, Never>] = [
      settings.$language.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$appearance.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$themeID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(sceneSettingsChanges)
      .sink { [weak self] in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    settings.$refreshInterval
      .removeDuplicates()
      .dropFirst()
      .sink { [weak monitor] interval in
        Task { @MainActor in
          monitor?.updateRefreshInterval(interval)
        }
      }
      .store(in: &cancellables)

    settings.$language
      .removeDuplicates()
      .dropFirst()
      .sink { [weak maintenance] language in
        Task { @MainActor in
          maintenance?.updateLanguage(language)
        }
      }
      .store(in: &cancellables)

    navigation.$destination
      .removeDuplicates()
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.updateMainWindowSampling()
        }
      }
      .store(in: &cancellables)

    bindMainWindowVisibility()
    bindUpdateChecking()
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true

    let menuBarController = MenuBarController(
      monitor: monitor,
      settings: settings,
      navigation: navigation
    )
    if let openMainWindowHandler {
      menuBarController.setOpenMainWindowHandler(openMainWindowHandler)
    }
    self.menuBarController = menuBarController
    monitor.updateRefreshInterval(settings.refreshInterval)
    monitor.start()
    maintenance.updateLanguage(settings.language)
    AppIconController.apply(settings.appIconStyle)
    updateChecker.checkIfNeeded()

    DispatchQueue.main.async { [weak self] in
      self?.updateMainWindowSampling()
    }
  }

  func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
    openMainWindowHandler = handler
    menuBarController?.setOpenMainWindowHandler(handler)
  }

  private func bindMainWindowVisibility() {
    let visibilityNotifications: [Notification.Name] = [
      NSApplication.didHideNotification,
      NSApplication.didUnhideNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]

    Publishers.MergeMany(
      visibilityNotifications.map {
        NotificationCenter.default.publisher(for: $0).eraseToAnyPublisher()
      }
    )
    .sink { [weak self] notification in
      Task { @MainActor in
        guard let self else { return }
        if let window = notification.object as? NSWindow {
          guard window.identifier == AppWindowActions.mainWindowIdentifier else { return }
          if window.isVisible {
            self.mainWindowIsClosing = false
          }
        }
        self.updateMainWindowSampling()
      }
    }
    .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
      .sink { [weak self] notification in
        Task { @MainActor in
          guard let self,
            let window = notification.object as? NSWindow,
            window.identifier == AppWindowActions.mainWindowIdentifier
          else {
            return
          }
          self.mainWindowIsClosing = true
          self.updateMainWindowSampling()
        }
      }
      .store(in: &cancellables)
  }

  private func bindUpdateChecking() {
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak updateChecker] _ in
        Task { @MainActor in
          updateChecker?.checkIfNeeded()
        }
      }
      .store(in: &cancellables)
  }

  private func updateMainWindowSampling() {
    let isMainWindowVisible: Bool
    if let window = AppWindowActions.mainWindow {
      isMainWindowVisible =
        !mainWindowIsClosing
        && !NSApp.isHidden
        && window.isVisible
        && !window.isMiniaturized
        && window.isOnActiveSpace
        && window.occlusionState.contains(.visible)
    } else {
      isMainWindowVisible = false
    }
    monitor.setMetricsSampling(isMainWindowVisible, for: .mainWindow)
    monitor.setProcessSampling(
      isMainWindowVisible && navigation.destination == .processes,
      for: .processManagement
    )
  }
}
