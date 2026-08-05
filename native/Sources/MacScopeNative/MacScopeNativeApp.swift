import SwiftUI

@main
@MainActor
struct MacScopeNativeApp: App {
  @StateObject private var runtime = AppRuntime()

  var body: some Scene {
    Window("MacScope", id: "main") {
      MacScopeRootView()
        .environmentObject(runtime.monitor)
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.settings)
        .environmentObject(runtime.maintenance)
        .environmentObject(runtime.startupItems)
        .environmentObject(runtime.navigation)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 1_020, minHeight: 620)
        .background {
          ZStack {
            MainWindowConfigurationView()
            MainWindowOpenActionBridge(runtime: runtime)
          }
            .allowsHitTesting(false)
        }
    }
    .defaultSize(width: 1_320, height: 800)
    .windowStyle(.titleBar)
    .commands {
      MacScopeCommands(language: runtime.settings.language)
    }

    Settings {
      SettingsView()
        .environmentObject(runtime.settings)
        .environmentObject(runtime.monitor.metrics)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(width: 840, height: 620)
        .background {
          SidebarHostingWindowConfigurationView()
            .allowsHitTesting(false)
        }
    }

    Window("MacScope Help", id: "help") {
      HelpView()
        .environmentObject(runtime.settings)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 680, minHeight: 480)
    }
    .defaultSize(width: 780, height: 560)
    .windowStyle(.titleBar)
  }
}

@MainActor
private struct MainWindowOpenActionBridge: View {
  @Environment(\.openWindow) private var openWindow

  let runtime: AppRuntime

  var body: some View {
    Color.clear
      .onAppear {
        let action = openWindow
        runtime.setOpenMainWindowHandler {
          action(id: "main")
        }
        runtime.start()
      }
  }
}
