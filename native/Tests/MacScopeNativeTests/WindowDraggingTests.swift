import AppKit
import SwiftUI
import Testing

@testable import MacScopeNative

extension AppAppearanceTests {
  @Test("Settings titlebar accepts native background dragging without capturing form controls")
  func settingsWindowDragging() throws {
    let suite = "WindowDraggingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let icons = AppIconController(settings: settings, imageLoader: { _ in nil })
    let content = SettingsView()
      .defaultAppStorage(defaults)
      .environmentObject(settings)
      .environmentObject(icons)
      .environmentObject(SystemMetricsStore())
      .environmentObject(UpdateChecker())
      .environmentObject(FanControlManager())
      .frame(width: 840, height: 620)
      .background { AppWindowConfigurationView().allowsHitTesting(false) }
    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.isReleasedWhenClosed = false
    window.orderBack(nil)
    defer { window.close() }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

    let contentView = try #require(window.contentView)
    let frameView = try #require(contentView.superview)
    #expect(window.isMovable && window.isMovableByWindowBackground)
    #expect(window.titlebarAppearsTransparent)
    let titlebarY = (window.contentLayoutRect.maxY + frameView.bounds.maxY) / 2
    for x: CGFloat in [320, 650, 800] {
      var hit: NSView? = try #require(frameView.hitTest(NSPoint(x: x, y: titlebarY)))
      while let view = hit {
        #expect(view.mouseDownCanMoveWindow, "Titlebar blocked by \(type(of: view)) at x=\(x)")
        hit = view.superview
      }
    }

    let form = try #require(descendantViews(contentView).compactMap { $0 as? NSScrollView }.first {
      $0.convert($0.bounds, to: frameView).midX > frameView.bounds.midX
    })
    #expect(!form.mouseDownCanMoveWindow)
    for x: CGFloat in [320, 650, 800] {
      let point = NSPoint(x: x, y: window.contentLayoutRect.maxY - 80)
      let hit = try #require(frameView.hitTest(point))
      #expect(hit === form || hit.isDescendant(of: form))
    }
  }
}

@MainActor
private func descendantViews(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + descendantViews($0) }
}
