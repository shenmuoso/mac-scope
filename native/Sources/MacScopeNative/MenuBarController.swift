import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
  private let monitor: SystemMonitor
  private let settings: AppSettings
  private let navigation: AppNavigation
  private let panel = MenuBarDashboardPanel()
  private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))

  private var statusItem: NSStatusItem?
  private var statusContentView: MenuBarNativeStatusView?
  private var localEventMonitor: Any?
  private var globalEventMonitor: Any?
  private var hideTask: Task<Void, Never>?
  private var pointerHasEntered = false
  private var menuTrackingDepth = 0
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
    hostingController.view.wantsLayer = true
    hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
    panel.delegate = self
    panel.setHostedView(hostingController.view)
    panel.onPointerChange = { [weak self] isInside in
      self?.pointerChanged(isInside: isInside)
    }

    bind()
    updateStatusItemAvailability(isEnabled: settings.menuBarEnabled)
  }

  func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
    openMainWindowHandler = handler
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    hideTask?.cancel()
    hideTask = nil
    removeEventMonitors()
    statusItem?.button?.highlight(false)
    statusContentView?.needsDisplay = true
    hostingController.rootView = AnyView(EmptyView())
    monitor.setMetricsSampling(false, for: .menuBar)
    monitor.setProcessSampling(false, for: .menuBar)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard notification.object as? NSWindow === panel, panel.isPresented,
      panel.attachedSheet == nil, menuTrackingDepth == 0
    else { return }
    dismissPanel()
  }

  private func bind() {
    settings.$menuBarEnabled
      .removeDuplicates()
      .sink { [weak self] isEnabled in
        self?.updateStatusItemAvailability(isEnabled: isEnabled)
      }
      .store(in: &cancellables)

    metricsChanges
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.updateStatusItemContent()
      }
      .store(in: &cancellables)

    let dashboardChanges: [AnyPublisher<Void, Never>] = [
      settings.$language.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$liquidGlassStyle.removeDuplicates().dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      settings.$themeID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$menuBarModules.removeDuplicates().dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
      settings.$menuBarProcessLimit.removeDuplicates().dropFirst().map { _ in () }
        .eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(dashboardChanges)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self else { return }
        if self.panel.isPresented {
          self.updateDashboardRootView()
          self.positionPanel()
        }
        self.updatePanelSampling()
      }
      .store(in: &cancellables)

    settings.$menuBarAutoHide
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isEnabled in
        guard let self else { return }
        if isEnabled { self.scheduleHideIfNeeded() } else { self.hideTask?.cancel() }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
      .sink { [weak self] _ in
        self?.menuTrackingDepth += 1
        self?.hideTask?.cancel()
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
        self.scheduleHideIfNeeded()
      }
      .store(in: &cancellables)
    NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        self.panel.updateMaterial(
          style: self.settings.liquidGlassStyle
        )
      }
      .store(in: &cancellables)

    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.panel.close() }
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
    button.action = #selector(toggleDashboard(_:))
    button.sendAction(on: [.leftMouseUp])

    statusItem = item
    updateStatusItemContent()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    panel.close()
    monitor.setMetricsSampling(false, for: .menuBar)
    monitor.setProcessSampling(false, for: .menuBar)
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    statusContentView = nil
  }

  private func updateStatusItemContent() {
    guard let statusItem, let button = statusItem.button else { return }
    let presentation = MenuBarStatusPresentation(
      snapshot: monitor.metrics.snapshot,
      displayMode: settings.menuBarDisplayMode,
      selectedMetrics: settings.menuBarMetrics,
      temperatureUnit: settings.temperatureUnit
    )

    button.title = ""
    if presentation.metrics.isEmpty {
      statusContentView?.removeFromSuperview()
      statusContentView = nil
      button.image = MenuBarLogoAsset.image
      button.imagePosition = .imageOnly
      statusItem.length = NSStatusItem.squareLength
    } else {
      let width = MenuBarStatusLayout(metrics: presentation.metrics).width
      if statusItem.length != width { statusItem.length = width }
      button.image = nil
      if statusContentView == nil {
        let view = MenuBarNativeStatusView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        statusContentView = view
      }
      statusContentView?.frame = button.bounds
      statusContentView?.presentation = presentation
    }
    button.setAccessibilityLabel(presentation.accessibilityLabel)
  }

  @objc private func toggleDashboard(_ sender: NSStatusBarButton) {
    if panel.isPresented {
      dismissPanel()
      return
    }

    hideTask?.cancel()
    if !panel.isVisible { updateDashboardRootView() }
    guard let anchor = positionPanel() else { return }
    pointerHasEntered = false
    sender.highlight(true)
    statusContentView?.needsDisplay = true
    panel.present(from: anchor)
    installEventMonitors()
    if panel.frame.contains(NSEvent.mouseLocation) { pointerChanged(isInside: true) }
    updatePanelSampling()
  }

  private func dismissPanel() {
    hideTask?.cancel()
    hideTask = nil
    panel.dismiss()
  }

  private func updatePanelSampling() {
    monitor.setMetricsSampling(panel.isVisible, for: .menuBar)
    monitor.setProcessSampling(
      panel.isVisible && settings.menuBarModules.contains(.processes),
      for: .menuBar
    )
  }

  private func dashboardRootView() -> AnyView {
    let maximumHeight = (statusItem?.button?.window?.screen?.visibleFrame.height ?? 800) - 20
    return AnyView(
      MenuBarDashboardView(
        maximumHeight: maximumHeight,
        openMainWindow: { [weak self] in self?.openMainWindow() },
        openSettings: { [weak self] in
          self?.dismissPanel()
          AppWindowActions.openSettings()
        }
      )
      .environmentObject(monitor)
      .environmentObject(monitor.metrics)
      .environmentObject(settings)
      .environmentObject(navigation)
      .environment(\.locale, settings.language.locale)
      .tint(settings.activeTheme.accentColor)
    )
  }

  private func updateDashboardRootView() {
    hostingController.rootView = dashboardRootView()
    hostingController.view.layoutSubtreeIfNeeded()
    panel.updateMaterial(style: settings.liquidGlassStyle)
    panel.setContentSize(MenuBarDashboardView.contentSize(
      modules: settings.menuBarModules,
      processLimit: settings.menuBarProcessLimit,
      maximumHeight: (statusItem?.button?.window?.screen?.visibleFrame.height ?? 800) - 20
    ))
  }

  private func openMainWindow() {
    dismissPanel()
    openMainWindowHandler?()
    DispatchQueue.main.async {
      AppWindowActions.activate()
      AppWindowActions.mainWindow?.makeKeyAndOrderFront(nil)
    }
  }

  @discardableResult
  private func positionPanel() -> NSRect? {
    guard let button = statusItem?.button, let window = button.window else { return nil }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
    let x = min(max(anchor.maxX - panel.frame.width, visibleFrame.minX + 8),
      visibleFrame.maxX - panel.frame.width - 8)
    let y = max(visibleFrame.minY + 8, anchor.minY - 6 - panel.frame.height)
    panel.setFrameOrigin(NSPoint(x: x, y: y))
    return anchor
  }

  private func pointerChanged(isInside: Bool) {
    if isInside {
      pointerHasEntered = true
      hideTask?.cancel()
    } else {
      scheduleHideIfNeeded()
    }
  }

  private func scheduleHideIfNeeded() {
    hideTask?.cancel()
    guard panel.isPresented, settings.menuBarAutoHide, pointerHasEntered,
      menuTrackingDepth == 0, panel.attachedSheet == nil
    else { return }

    hideTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard let self, !Task.isCancelled, self.panel.isPresented,
        self.settings.menuBarAutoHide, self.menuTrackingDepth == 0,
        self.panel.attachedSheet == nil,
        !self.panel.frame.contains(NSEvent.mouseLocation)
      else { return }
      self.dismissPanel()
    }
  }

  private func installEventMonitors() {
    removeEventMonitors()
    localEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown]
    ) { [weak self] event in
      guard let self, self.panel.isPresented else { return event }
      if event.type == .keyDown {
        if event.keyCode == 53, event.window === self.panel, self.panel.attachedSheet == nil {
          self.dismissPanel()
          return nil
        }
      } else {
        self.closeIfPointerIsOutside()
      }
      return event
    }
    globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.closeIfPointerIsOutside()
    }
  }

  private func closeIfPointerIsOutside() {
    guard panel.isPresented, menuTrackingDepth == 0, panel.attachedSheet == nil,
      !panel.frame.contains(NSEvent.mouseLocation)
    else { return }
    if let button = statusItem?.button, let window = button.window {
      let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
      if anchor.contains(NSEvent.mouseLocation) { return }
    }
    dismissPanel()
  }

  private func removeEventMonitors() {
    if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
    localEventMonitor = nil
    globalEventMonitor = nil
  }
}
