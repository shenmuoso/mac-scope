import AppKit
import Combine

@MainActor
final class AppRuntime: ObservableObject {
  let monitor: SystemMonitor
  let settings: AppSettings
  let maintenance: MaintenanceStore
  let navigation: AppNavigation

  private var menuBarController: MenuBarController?
  private var openMainWindowHandler: (() -> Void)?
  private var hasStarted = false
  private var cancellables: Set<AnyCancellable> = []

  init() {
    monitor = SystemMonitor()
    settings = AppSettings()
    maintenance = MaintenanceStore()
    navigation = AppNavigation()

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
  }

  func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
    openMainWindowHandler = handler
    menuBarController?.setOpenMainWindowHandler(handler)
  }
}
