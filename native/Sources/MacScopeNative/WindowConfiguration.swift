import AppKit
import SwiftUI

struct AppWindowConfigurationView: NSViewRepresentable {
  var isMainWindow = false

  func makeNSView(context: Context) -> WindowConfigurationView {
    WindowConfigurationView(isMainWindow: isMainWindow)
  }

  func updateNSView(_ view: WindowConfigurationView, context: Context) {
    view.configureWindow()
  }
}

final class WindowConfigurationView: NSView {
  private let isMainWindow: Bool
  private weak var configuredWindow: NSWindow?

  init(isMainWindow: Bool) {
    self.isMainWindow = isMainWindow
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindow()
  }

  func configureWindow() {
    guard let window else { return }
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    // Full-size content covers the titlebar; let its noninteractive views remain draggable.
    window.isMovableByWindowBackground = true
    window.titlebarSeparatorStyle = .none
    window.toolbarStyle = .unified

    guard configuredWindow !== window else { return }
    configuredWindow = window
    if isMainWindow {
      window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
      window.identifier = AppWindowActions.mainWindowIdentifier
      window.contentMinSize = NSSize(width: 1_020, height: 620)
      window.contentResizeIncrements = NSSize(width: 1, height: 1)
      window.collectionBehavior.insert(.fullScreenPrimary)
      window.standardWindowButton(.zoomButton)?.isEnabled = true
      window.standardWindowButton(.zoomButton)?.isHidden = false
      _ = window.setFrameAutosaveName("MacScope.MainWindow")
    }
  }
}
