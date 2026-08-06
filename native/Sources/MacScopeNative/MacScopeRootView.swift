import SwiftUI

struct MacScopeRootView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var navigation: AppNavigation
  @EnvironmentObject private var updateChecker: UpdateChecker

  private var destinationSelection: Binding<AppDestination?> {
    Binding(
      get: { navigation.destination },
      set: {
        let nextDestination = $0 ?? .overview
        guard navigation.destination != nextDestination else { return }
        navigation.destination = nextDestination
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: destinationSelection) {
          Section("Monitor") {
            sidebarRow(.overview)
            sidebarRow(.performancePower)
            sidebarRow(.processes)
          }
          Section("Hardware") {
            sidebarRow(.systemInfo)
            sidebarRow(.battery)
          }
          Section("System Tools") {
            sidebarRow(.ports)
            sidebarRow(.startupItems)
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
    Group {
      if let update = updateChecker.availableUpdate {
        Button(action: updateChecker.downloadAvailableUpdate) {
          sidebarFooterContent(update: update)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
          AppLocalization.string(
            "A newer version of MacScope is available on GitHub.",
            language: settings.language
          )
        )
        .accessibilityLabel(downloadTitle(for: update))
      } else {
        sidebarFooterContent(update: nil)
      }
    }
    .frame(height: 48)
    .padding(.horizontal, 14)
  }

  private func sidebarFooterContent(update: AvailableUpdate?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Version \(AppMetadata.version)")
        .monospacedDigit()
        .font(.caption)
        .foregroundStyle(.tertiary)

      if let update {
        HStack(spacing: 4) {
          Image(systemName: "arrow.down.circle.fill")
          Text(downloadTitle(for: update))
            .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.tint)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private func downloadTitle(for update: AvailableUpdate) -> String {
    AppLocalization.string(
      "Download %@",
      language: settings.language,
      arguments: [update.version]
    )
  }

  @ViewBuilder
  private var detailContent: some View {
    switch navigation.destination {
    case .overview:
      DashboardView()
    case .performancePower:
      PerformancePowerView()
    case .processes:
      ProcessManagementView()
    case .systemInfo:
      HardwareInfoView()
    case .battery:
      BatteryHealthView()
    case .ports:
      PortToolView()
    case .startupItems:
      StartupItemsView()
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
