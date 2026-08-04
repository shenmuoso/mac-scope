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
  private var statusContentView: MenuBarStatusItemContentView?
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
    updateDashboardRootView()

    bind()
    updateStatusItemAvailability(isEnabled: settings.menuBarEnabled)
  }

  func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
    openMainWindowHandler = handler
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem?.button?.highlight(false)
    monitor.setProcessSampling(false, for: .menuBar)
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
        self.updateDashboardRootView()
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

    let contentView = MenuBarStatusItemContentView()
    contentView.frame = button.bounds
    contentView.autoresizingMask = [.width, .height]
    button.image = nil
    button.title = ""
    button.toolTip = "MacScope"
    button.target = self
    button.action = #selector(togglePopover(_:))
    button.sendAction(on: [.leftMouseUp])
    // Clearing the native image/title removes the button's intrinsic vertical size.
    button.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true
    button.addSubview(contentView)

    statusItem = item
    statusContentView = contentView
    updateStatusItemContent()
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    popover.close()
    monitor.setProcessSampling(false, for: .menuBar)
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
    statusContentView = nil
  }

  private func updateStatusItemContent() {
    guard let statusItem, let contentView = statusContentView else { return }
    let presentation = MenuBarStatusPresentation(
      snapshot: monitor.metrics.snapshot,
      displayMode: settings.menuBarDisplayMode,
      selectedMetrics: settings.menuBarMetrics,
      temperatureUnit: settings.temperatureUnit
    )

    contentView.compactText = presentation.compactText
    statusItem.length = contentView.requiredWidth
    statusItem.button?.setAccessibilityLabel(presentation.accessibilityLabel)
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
      return
    }

    updateDashboardRootView()
    sender.highlight(true)
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
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

@MainActor
private final class MenuBarStatusItemContentView: NSView {
  private enum Metrics {
    static let horizontalInset: CGFloat = 5
    static let iconSize: CGFloat = 16
    static let iconToTextSpacing: CGFloat = 10
  }

  private let iconView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private lazy var compactIconLeadingConstraint = iconView.leadingAnchor.constraint(
    equalTo: leadingAnchor,
    constant: Metrics.horizontalInset
  )
  private lazy var iconOnlyCenterConstraint = iconView.centerXAnchor.constraint(
    equalTo: centerXAnchor
  )
  private lazy var titleLeadingConstraint = titleField.leadingAnchor.constraint(
    equalTo: iconView.trailingAnchor,
    constant: Metrics.iconToTextSpacing
  )
  private var showsCompactText: Bool?

  var compactText: String? {
    didSet { updateContent() }
  }

  var requiredWidth: CGFloat {
    guard compactText != nil else { return NSStatusItem.squareLength }
    return ceil(
      Metrics.horizontalInset + Metrics.iconSize + Metrics.iconToTextSpacing
        + titleField.intrinsicContentSize.width + Metrics.horizontalInset
    )
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    iconView.image = MenuBarLogoAsset.image
    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = .labelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let menuBarPointSize = NSFont.menuBarFont(ofSize: 0).pointSize
    titleField.font = .monospacedDigitSystemFont(ofSize: menuBarPointSize, weight: .regular)
    titleField.textColor = .labelColor
    titleField.lineBreakMode = .byClipping
    titleField.maximumNumberOfLines = 1
    titleField.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(titleField)

    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    updateContent()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Preserve the status bar button as the sole native click target.
    nil
  }

  private func updateContent() {
    let showsText = compactText != nil
    titleField.stringValue = compactText ?? ""
    titleField.isHidden = !showsText
    guard showsCompactText != showsText else { return }
    showsCompactText = showsText

    if showsText {
      NSLayoutConstraint.deactivate([iconOnlyCenterConstraint])
      NSLayoutConstraint.activate([compactIconLeadingConstraint, titleLeadingConstraint])
    } else {
      NSLayoutConstraint.deactivate([compactIconLeadingConstraint, titleLeadingConstraint])
      NSLayoutConstraint.activate([iconOnlyCenterConstraint])
    }
  }
}
