import AppKit
import Testing

@testable import MacScopeNative

extension AppAppearanceTests {
  @Test("Dock icon follows effective appearance, preserves overrides, and restores automatic mode")
  func dockIconAppearance() throws {
    let application = NSApplication.shared
    let originalAppearance = application.appearance
    let originalIcon = application.applicationIconImage
    let suite = "AppIconAppearanceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      application.appearance = originalAppearance
      application.applicationIconImage = originalIcon
      defaults.removePersistentDomain(forName: suite)
    }
    let settings = AppSettings(defaults: defaults)
    settings.appearance = .light
    let appearanceController = AppAppearanceController(settings: settings)
    let light = solidIcon(color: .white)
    let dark = solidIcon(color: .black)
    var loads = 0
    let icons = AppIconController(settings: settings) { isDark in
      loads += 1
      return isDark ? dark : light
    }

    try withExtendedLifetime((appearanceController, icons)) {
      #expect(icons.image === light)
      let initialIsDark = try iconIsDark(application.applicationIconImage)
      #expect(!initialIsDark)
      for appearance in [AppAppearance.dark, .light, .dark] {
        settings.appearance = appearance
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        #expect(icons.image === (appearance == .dark ? dark : light))
        let actualIsDark = try iconIsDark(application.applicationIconImage)
        #expect(actualIsDark == (appearance == .dark))
      }

      settings.dockIconAppearance = .light
      #expect(icons.image === light)
      #expect(AppSettings(defaults: defaults).dockIconAppearance == .light)
      settings.dockIconAppearance = .dark
      settings.appearance = .light
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      #expect(icons.image === dark)
      let fixedIsDark = try iconIsDark(application.applicationIconImage)
      #expect(fixedIsDark)
      application.applicationIconImage = light
      icons.refresh()
      let restoredIsDark = try iconIsDark(application.applicationIconImage)
      #expect(restoredIsDark)

      settings.dockIconAppearance = .automatic
      #expect(icons.image === light)
      settings.appearance = .system
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      let systemIsDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      #expect(icons.image === (systemIsDark ? dark : light))

      // Exercise the notification path with unchanged settings, as with a system theme change.
      for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        application.appearance = NSAppearance(named: appearance)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        #expect(settings.appearance == .system)
        #expect(icons.image === (appearance == .darkAqua ? dark : light))
      }
      #expect(loads == 2)
      settings.dockIconAppearance = .dark
      settings.resetAll()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
      #expect(AppSettings(defaults: defaults).dockIconAppearance == .automatic)
      let resetIsDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      #expect(icons.image === (resetIsDark ? dark : light))
    }
  }
}

@MainActor
private func solidIcon(color: NSColor) -> NSImage {
  NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
    color.setFill()
    bounds.fill()
    return true
  }
}

private func iconIsDark(_ image: NSImage) throws -> Bool {
  let tiff = try #require(image.tiffRepresentation)
  let bitmap = try #require(NSBitmapImageRep(data: tiff))
  let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
  let rgb = try #require(color.usingColorSpace(.deviceRGB))
  return rgb.redComponent < 0.5
}
