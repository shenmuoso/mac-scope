import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
  private let monitor: SystemMonitor
  private let settings: AppSettings
  private let navigation: AppNavigation
  private let popover = NSPopover()
  private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))

  private var statusItem: NSStatusItem?
  private var statusShowsCompactText: Bool?
  private var openMainWindowHandler: (() -> Void)?
  private var cancellables: Set<AnyCancellable> = []

  init(
    monitor: SystemMonitor,
    settings: AppSettings,
    navigation: AppNavigation
  ) {
    self.monitor = monitor
    self.settings = settings
    self.navigation = navigation
    super.init()

    hostingController.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentViewController = hostingController

    bind()
    updateStatusItemAvailability(isEnabled: settings.menuBarEnabled)
  }

  func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
    openMainWindowHandler = handler
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem?.button?.highlight(false)
    hostingController.rootView = AnyView(EmptyView())
    updatePopoverSampling()
  }

  func popoverDidShow(_ notification: Notification) {
    updatePopoverSampling()
  }

  private func bind() {
    settings.$menuBarEnabled
      .removeDuplicates()
      .sink { [weak self] isEnabled in
        self?.updateStatusItemAvailability(isEnabled: isEnabled)
      }
      .store(in: &cancellables)

    metricsChanges
      .sink { [weak self] in
        self?.updateStatusItemContent()
      }
      .store(in: &cancellables)

    let dashboardChanges: [AnyPublisher<Void, Never>] = [
      settings.$language.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$appearance.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$themeID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$menuBarModules.removeDuplicates().dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      settings.$menuBarProcessLimit.removeDuplicates().dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(dashboardChanges)
      .sink { [weak self] in
        guard let self else { return }
        if self.popover.isShown {
          self.updateDashboardRootView()
        }
        self.updatePopoverSampling()
      }
      .store(in: &cancellables)
  }

  private var metricsChanges: AnyPublisher<Void, Never> {
    Publishers.Merge4(
      monitor.metrics.$snapshot.map { _ in () }.eraseToAnyPublisher(),
      settings.$menuBarDisplayMode.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      settings.$menuBarMetrics.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      settings.$temperatureUnit.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    )
    .eraseToAnyPublisher()
  }

  private func updateStatusItemAvailability(isEnabled: Bool) {
    if isEnabled {
      guard statusItem == nil else {
        updateStatusItemContent()
        return
      }
      installStatusItem()
    } else {
      removeStatusItem()
    }
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else {
      NSStatusBar.system.removeStatusItem(item)
      return
    }

    button.image = MenuBarLogoAsset.image
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.imageHugsTitle = true
    button.font = .monospacedDigitSystemFont(
      ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
      weight: .regular
    )
    button.title = ""
    button.toolTip = "MacScope"
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.sendAction(on: [.leftMouseUp])

    statusItem = item
    updateStatusItemContent()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    popover.close()
    monitor.setMetricsSampling(false, for: .menuBar)
    monitor.setProcessSampling(false, for: .menuBar)
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    statusShowsCompactText = nil
  }

  private func updateStatusItemContent() {
    guard let statusItem, let button = statusItem.button else { return }
    let presentation = MenuBarStatusPresentation(
      snapshot: monitor.metrics.snapshot,
      displayMode: settings.menuBarDisplayMode,
      selectedMetrics: settings.menuBarMetrics,
      temperatureUnit: settings.temperatureUnit
    )

    let compactText = presentation.compactText
    let showsCompactText = compactText != nil
    if statusShowsCompactText != showsCompactText {
      statusShowsCompactText = showsCompactText
      button.image = showsCompactText
        ? MenuBarLogoAsset.compactStatusImage
        : MenuBarLogoAsset.image
      button.imagePosition = showsCompactText ? .imageLeading : .imageOnly
      statusItem.length = showsCompactText
        ? NSStatusItem.variableLength
        : NSStatusItem.squareLength
    }
    let title = compactText ?? ""
    if button.title != title {
      button.title = title
    }
    button.setAccessibilityLabel(presentation.accessibilityLabel)
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
      return
    }

    updateDashboardRootView()
    sender.highlight(true)
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    updatePopoverSampling()
  }

  private func updatePopoverSampling() {
    monitor.setMetricsSampling(popover.isShown, for: .menuBar)
    monitor.setProcessSampling(
      popover.isShown && settings.menuBarModules.contains(.processes),
      for: .menuBar
    )
  }

  private func dashboardRootView() -> AnyView {
    AnyView(
      MenuBarDashboardView { [weak self] in
        self?.openMainWindow()
      }
      .environmentObject(monitor)
      .environmentObject(monitor.metrics)
      .environmentObject(settings)
      .environmentObject(navigation)
      .environment(\.locale, settings.language.locale)
      .preferredColorScheme(settings.appearance.colorScheme)
      .tint(settings.activeTheme.accentColor)
    )
  }

  private func updateDashboardRootView() {
    hostingController.rootView = dashboardRootView()
    hostingController.view.layoutSubtreeIfNeeded()
    popover.contentSize = hostingController.view.fittingSize
  }

  private func openMainWindow() {
    popover.performClose(nil)
    openMainWindowHandler?()
    DispatchQueue.main.async {
      AppWindowActions.activate()
      AppWindowActions.mainWindow?.makeKeyAndOrderFront(nil)
    }
  }
}
