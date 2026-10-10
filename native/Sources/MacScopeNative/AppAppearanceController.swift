import AppKit
import Combine

@MainActor
final class AppAppearanceController {
  private let observation: AnyCancellable

  init(settings: AppSettings, application: NSApplication = .shared) {
    observation = settings.$appearance
      .removeDuplicates()
      .sink { appearance in
        // All windows and hosting views inherit this override. Nil restores live system updates.
        switch appearance {
        case .system:
          application.appearance = nil
        case .light:
          application.appearance = NSAppearance(named: .aqua)
        case .dark:
          application.appearance = NSAppearance(named: .darkAqua)
        }
      }
  }
}
