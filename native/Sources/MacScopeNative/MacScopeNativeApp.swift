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
        .environmentObject(runtime.iconController)
        .environmentObject(runtime.maintenance)
        .environmentObject(runtime.startupItems)
        .environmentObject(runtime.navigation)
        .environmentObject(runtime.updateChecker)
        .environmentObject(runtime.fanControl)
        .environmentObject(runtime.audio)
        .environment(\.locale, runtime.settings.language.locale)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 1_020, minHeight: 620)
        .background {
          ZStack {
            AppWindowConfigurationView(isMainWindow: true)
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
        .environmentObject(runtime.iconController)
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.updateChecker)
        .environmentObject(runtime.fanControl)
        .environment(\.locale, runtime.settings.language.locale)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(width: 840, height: 620)
        .background {
          AppWindowConfigurationView()
            .allowsHitTesting(false)
        }
    }

    Window("MacScope Help", id: "help") {
      HelpView()
        .environmentObject(runtime.settings)
        .environmentObject(runtime.iconController)
        .environment(\.locale, runtime.settings.language.locale)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 680, minHeight: 480)
        .background {
          AppWindowConfigurationView()
            .allowsHitTesting(false)
        }
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
