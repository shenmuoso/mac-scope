import AppKit
import QuartzCore
import Testing

@testable import MacScopeNative

// AppKit tests share the application and main run loop, so use the serialized window suite.
extension AppAppearanceTests {
  @Test("Zoom keeps content size stable and closes only after the exit animation")
  func animatedPresentation() async throws {
    let panel = makePanel()
    let observer = PanelCloseObserver()
    panel.delegate = observer
    defer { panel.close() }
    let originalFrame = panel.frame
    let content = try #require(panel.contentView)
    let originalBounds = content.bounds

    panel.present(from: anchor(for: panel))
    #expect(panel.isPresented)
    #expect(panel.presentationState == .opening)
    await advance(by: 0.07)
    let opening = try #require(content.layer?.presentation())
    #expect(opening.transform.m11 > 0.12 && opening.transform.m11 < 1)
    #expect(panel.frame == originalFrame)
    #expect(content.bounds == originalBounds)
    await advance(by: 0.4)
    #expect(panel.presentationState == .shown)
    #expect(content.layer?.transform.m11 == 1)

    panel.dismiss()
    #expect(panel.isVisible)
    #expect(!panel.isPresented)
    #expect(panel.ignoresMouseEvents)
    #expect(observer.closeCount == 0)
    await advance(by: 0.35)
    #expect(!panel.isVisible)
    #expect(panel.presentationState == .hidden)
    #expect(observer.closeCount == 1)
    #expect(content.layer?.transform.m11 == 1)
    #expect(content.layer?.opacity == 1)

    panel.present(from: anchor(for: panel))
    await advance(by: 0.07)
    let reopening = try #require(content.layer?.presentation())
    #expect(reopening.transform.m11 > 0.12 && reopening.transform.m11 < 1)
    await advance(by: 0.4)
    #expect(panel.presentationState == .shown)
    #expect(observer.closeCount == 1)
  }

  @Test("Rapid toggles reverse the current pose without stale close callbacks")
  func reversePresentation() async throws {
    let panel = makePanel()
    let observer = PanelCloseObserver()
    panel.delegate = observer
    defer { panel.close() }
    let origin = anchor(for: panel)

    panel.present(from: origin)
    await advance(by: 0.05)
    panel.dismiss()
    await advance(by: 0.05)
    let scaleBeforeReopening = try #require(panel.contentView?.layer?.presentation()).transform.m11
    panel.present(from: origin)
    let animation = try #require(
      panel.contentView?.layer?.animation(forKey: "menuBarPresentation") as? CAAnimationGroup)
    let transform = try #require(animation.animations?.first as? CABasicAnimation)
    let fromValue = try #require(transform.fromValue as? NSValue)
    #expect(abs(fromValue.caTransform3DValue.m11 - scaleBeforeReopening) < 0.05)
    await advance(by: 0.5)
    #expect(panel.isVisible)
    #expect(panel.presentationState == .shown)
    #expect(!panel.ignoresMouseEvents)
    #expect(observer.closeCount == 0)
  }

  @Test("Immediate teardown cancels pending animation completions before reopening")
  func immediateDismissal() async {
    let panel = makePanel()
    let observer = PanelCloseObserver()
    panel.delegate = observer
    defer { panel.close() }
    let origin = anchor(for: panel)

    panel.present(from: origin)
    await advance(by: 0.04)
    panel.dismiss(animated: false)
    #expect(!panel.isVisible)
    #expect(panel.presentationState == .hidden)
    #expect(observer.closeCount == 1)
    panel.present(from: origin, animated: false)
    await advance(by: 0.45)
    #expect(panel.isVisible)
    #expect(panel.presentationState == .shown)
    #expect(observer.closeCount == 1)
    #expect(panel.contentView?.layer?.animationKeys()?.isEmpty != false)
  }

  @Test("Reduced motion uses a short fade with no scaling, including Escape dismissal")
  func reducedMotion() async throws {
    let panel = makePanel(reduceMotion: true)
    defer { panel.close() }
    panel.present(from: anchor(for: panel))
    let animation = try #require(
      panel.contentView?.layer?.animation(forKey: "menuBarPresentation") as? CAAnimationGroup)
    #expect(animation.animations?.count == 1)
    #expect((animation.animations?.first as? CABasicAnimation)?.keyPath == "opacity")
    await advance(by: 0.2)
    #expect(panel.presentationState == .shown)
    #expect(panel.contentView?.layer?.transform.m11 == 1)
    panel.cancelOperation(nil)
    #expect(panel.presentationState == .closing)
    #expect(panel.contentView?.layer?.transform.m11 == 1)
    await advance(by: 0.2)
    #expect(!panel.isVisible)
  }

  private func makePanel(reduceMotion: Bool = false) -> MenuBarDashboardPanel {
    _ = NSApplication.shared
    let panel = MenuBarDashboardPanel(reduceMotion: { reduceMotion })
    panel.setFrameOrigin(NSPoint(x: 100, y: 100))
    let content = NSTextField(labelWithString: "CPU 42%")
    panel.setHostedView(content)
    NSLayoutConstraint.activate([
      content.widthAnchor.constraint(equalToConstant: 390),
      content.heightAnchor.constraint(equalToConstant: 500),
    ])
    return panel
  }

  private func anchor(for panel: MenuBarDashboardPanel) -> NSRect {
    NSRect(x: panel.frame.maxX - 28, y: panel.frame.maxY + 6, width: 28, height: 24)
  }

  private func advance(by interval: TimeInterval) async {
    try? await Task.sleep(for: .seconds(interval))
  }
}

@MainActor
private final class PanelCloseObserver: NSObject, NSWindowDelegate {
  var closeCount = 0

  func windowWillClose(_ notification: Notification) {
    closeCount += 1
  }
}
