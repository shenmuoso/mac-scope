import SwiftUI

struct MacScopeRootView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var navigation: AppNavigation

  private var destinationSelection: Binding<AppDestination?> {
    Binding(
      get: { navigation.destination },
      set: {
        let nextDestination = $0 ?? .overview
        guard navigation.destination != nextDestination else { return }
        if navigation.destination == .overview {
          monitor.setProcessSampling(false, for: .overview)
        }
        navigation.destination = nextDestination
        if nextDestination == .overview {
          monitor.setProcessSampling(true, for: .overview)
        }
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: destinationSelection) {
          Section("Monitor") {
            sidebarRow(.overview)
          }
          Section("Hardware") {
            sidebarRow(.systemInfo)
            sidebarRow(.battery)
          }
          Section("System Tools") {
            sidebarRow(.ports)
            sidebarRow(.downloads)
            sidebarRow(.junk)
            sidebarRow(.applications)
            sidebarRow(.largeFiles)
            sidebarRow(.duplicates)
            sidebarRow(.memory)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .compactNativeScrollers(clearsBackground: true)

        Divider()
        sidebarFooter
      }
      .background {
        SidebarMaterialView(
          isEnabled: settings.sidebarTransparencyEnabled,
          transparency: settings.sidebarTransparency
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }
      .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 280)
    } detail: {
      detailContent
        .navigationTitle("")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        }
        .clipped()
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if #available(macOS 14.0, *) {
          SettingsLink {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Settings")
        } else {
          Button(action: AppWindowActions.openSettings) {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Settings")
        }
      }
    }
    .onAppear {
      monitor.setProcessSampling(navigation.destination == .overview, for: .overview)
    }
    .onDisappear {
      monitor.setProcessSampling(false, for: .overview)
    }
  }

  private func sidebarRow(_ item: AppDestination) -> some View {
    HStack(spacing: 10) {
      SidebarItemIcon(systemImage: item.systemImage, color: item.iconColor)

      Text(item.title)
        .lineLimit(1)
    }
      .padding(.vertical, 2)
      .tag(item)
      .listRowBackground(Color.clear)
  }

  private var sidebarFooter: some View {
    Text("Version \(AppMetadata.version)")
      .monospacedDigit()
      .font(.caption)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
  }

  @ViewBuilder
  private var detailContent: some View {
    switch navigation.destination {
    case .overview:
      DashboardView()
    case .systemInfo:
      HardwareInfoView()
    case .battery:
      BatteryHealthView()
    case .ports:
      PortToolView()
    case .downloads:
      DownloadCleanupView()
    case .junk:
      JunkCleanupView()
    case .applications:
      ApplicationsToolView()
    case .largeFiles:
      FileCleanupView(tool: .largeFiles)
    case .duplicates:
      FileCleanupView(tool: .duplicates)
    case .memory:
      MemoryToolView()
    }
  }

}
