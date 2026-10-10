import AppKit
import Combine
import SwiftUI

@MainActor
final class AppIconController: ObservableObject {
  @Published private(set) var image: NSImage?

  private let application: NSApplication
  private let imageLoader: (Bool) -> NSImage?
  private var preference: DockIconAppearance
  private var images: [Bool: NSImage] = [:]
  private var appliedDarkAppearance: Bool?
  private var cancellables: Set<AnyCancellable> = []

  init(
    settings: AppSettings,
    application: NSApplication = .shared,
    imageLoader: ((Bool) -> NSImage?)? = nil
  ) {
    self.application = application
    self.imageLoader = imageLoader ?? Self.loadImage
    preference = settings.dockIconAppearance

    settings.$dockIconAppearance
      .removeDuplicates()
      .sink { [weak self] preference in
        self?.preference = preference
        self?.updateIcon()
      }
      .store(in: &cancellables)

    // Effective appearance changes for both app overrides and live system theme changes.
    application.publisher(for: \.effectiveAppearance, options: [.new])
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateIcon()
      }
      .store(in: &cancellables)
  }

  func refresh() {
    updateIcon(force: true)
  }

  private func updateIcon(force: Bool = false) {
    let isDark: Bool
    switch preference {
    case .automatic:
      isDark = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    case .light:
      isDark = false
    case .dark:
      isDark = true
    }
    guard force || appliedDarkAppearance != isDark,
      let image = images[isDark] ?? imageLoader(isDark)
    else { return }

    images[isDark] = image
    appliedDarkAppearance = isDark
    self.image = image
    application.applicationIconImage = image
  }

  private static func loadImage(isDark: Bool) -> NSImage? {
    let resource = isDark ? "MacScopeDockDark" : "MacScopeDockLight"
    guard let url = Bundle.main.url(forResource: resource, withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
  }
}

struct AppIconImage: View {
  @EnvironmentObject private var iconController: AppIconController

  var body: some View {
    Image(nsImage: iconController.image ?? NSApp.applicationIconImage)
      .resizable()
      .aspectRatio(contentMode: .fit)
  }
}
