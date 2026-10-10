import AppKit
import SwiftUI
import Testing

@testable import MacScopeNative

@Suite("Window appearance", .serialized)
@MainActor
struct AppAppearanceTests {
  @Test("Existing and newly opened windows inherit appearance and release manual overrides")
  func appearanceInheritance() throws {
    let application = NSApplication.shared
    let originalAppearance = application.appearance
    let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      application.appearance = originalAppearance
      defaults.removePersistentDomain(forName: suiteName)
    }
    application.appearance = nil
    let systemAppearance = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    let settings = AppSettings(defaults: defaults)
    let controller = AppAppearanceController(settings: settings, application: application)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    let windowScheme = AppearanceRecorder()
    let panelScheme = AppearanceRecorder()
    window.contentView = NSHostingView(rootView: AppearanceProbe(recorder: windowScheme))
    let panel = MenuBarDashboardPanel()
    panel.setHostedView(NSHostingView(rootView: AppearanceProbe(recorder: panelScheme)))
    window.orderBack(nil)
    panel.orderFront(nil)
    defer {
      window.close()
      panel.close()
    }

    withExtendedLifetime(controller) {
      for (appearance, expected) in [
        (AppAppearance.dark, NSAppearance.Name.darkAqua),
        (.light, .aqua),
        (.dark, .darkAqua),
      ] {
        settings.appearance = appearance
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        for target in [window, panel] {
          #expect(target.appearance == nil)
          #expect(target.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
          #expect(target.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }
        let expectedScheme: ColorScheme = appearance == .dark ? .dark : .light
        #expect(windowScheme.colorScheme == expectedScheme)
        #expect(panelScheme.colorScheme == expectedScheme)

        let newWindow = NSWindow()
        newWindow.isReleasedWhenClosed = false
        #expect(newWindow.appearance == nil)
        #expect(newWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        newWindow.close()

        settings.appearance = .system
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(application.appearance == nil)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == systemAppearance)
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == systemAppearance)
        let systemScheme: ColorScheme = systemAppearance == .darkAqua ? .dark : .light
        #expect(windowScheme.colorScheme == systemScheme)
        #expect(panelScheme.colorScheme == systemScheme)
      }
      #expect(AppSettings(defaults: defaults).appearance == .system)
    }
  }

  @Test("Switching panel materials retains its hosted content and inherited appearance")
  func panelMaterialChanges() throws {
    let panel = MenuBarDashboardPanel()
    let content = NSHostingView(rootView: Text("CPU 42%"))
    panel.setHostedView(content)
    let originalRoot = try #require(panel.contentView)
    defer { panel.close() }

    for style in [LiquidGlassStyle.glass, .balanced, .frosted, .glass] {
      panel.updateMaterial(style: style)
      panel.setContentSize(NSSize(width: 390, height: 440))
      let root = try #require(panel.contentView)
      #expect(root === originalRoot)
      panel.orderFront(nil)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
      root.layoutSubtreeIfNeeded()
      #expect(content.isDescendant(of: root))
      #expect(content.window === panel)
      #expect(content.frame.size == root.bounds.size, "Material: \(style)")
      #expect(panel.appearance == nil)
      if #available(macOS 26.0, *),
        !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
        style != .frosted
      {
        let glass = try #require(root.subviews.first as? NSGlassEffectView)
        #expect(glass.style == .regular)
      }
    }
  }
}

@MainActor
private final class AppearanceRecorder {
  var colorScheme: ColorScheme?
}

private struct AppearanceProbe: View {
  @Environment(\.colorScheme) private var colorScheme
  let recorder: AppearanceRecorder

  var body: some View {
    Text("Appearance")
      .onAppear { recorder.colorScheme = colorScheme }
      .onChange(of: colorScheme) { recorder.colorScheme = $0 }
  }
}
