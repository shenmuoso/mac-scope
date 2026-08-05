import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case menuBar
  case appearance
  case cleanup
  case permissions
  case about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .menuBar: "Menu Bar"
    case .appearance: "Appearance"
    case .cleanup: "Cleanup"
    case .permissions: "Permission Management"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gear"
    case .menuBar: "switch.2"
    case .appearance: "circle.lefthalf.filled"
    case .cleanup: "trash"
    case .permissions: "hand.raised.fill"
    case .about: "info.circle"
    }
  }

  var iconColor: Color {
    switch self {
    case .general, .about:
      Color(nsColor: .systemGray)
    case .menuBar:
      Color(nsColor: .systemPurple)
    case .appearance, .permissions:
      Color(nsColor: .systemBlue)
    case .cleanup:
      Color(nsColor: .systemRed)
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var metrics: SystemMetricsStore
  @Environment(\.openWindow) private var openWindow

  @StateObject private var permissionManager = PermissionManager()
  @AppStorage("native.settingsTab") private var selectedTab = "general"
  @State private var selectedScanFolder: String?
  @State private var confirmsReset = false

  private var activePane: SettingsPane {
    SettingsPane(rawValue: selectedTab) ?? .general
  }

  private var paneSelection: Binding<String?> {
    Binding(
      get: { selectedTab },
      set: { value in
        if let value, SettingsPane(rawValue: value) != nil {
          selectedTab = value
        }
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: paneSelection) {
          Section {
            ForEach(SettingsPane.allCases.filter { $0 != .about }) { pane in
              settingsSidebarRow(pane)
            }
          }

          Section {
            settingsSidebarRow(.about)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .compactNativeScrollers(clearsBackground: true)

        Divider()
        Text("Version \(AppMetadata.version)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
      }
      .background {
        SidebarMaterialView(
          isEnabled: settings.sidebarTransparencyEnabled,
          transparency: settings.sidebarTransparency
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 230)
    } detail: {
      settingsDetail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        }
        .navigationTitle(activePane.title)
    }
    .navigationSplitViewStyle(.balanced)
    .alert("Reset all settings?", isPresented: $confirmsReset) {
      Button("Reset", role: .destructive, action: settings.resetAll)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Monitoring, menu bar, appearance, and cleanup preferences will return to their defaults.")
    }
  }

  private func settingsSidebarRow(_ pane: SettingsPane) -> some View {
    HStack(spacing: 10) {
      SidebarItemIcon(systemImage: pane.systemImage, color: pane.iconColor)

      Text(pane.title)
        .lineLimit(1)
    }
    .padding(.vertical, 2)
    .tag(pane.rawValue)
  }

  @ViewBuilder
  private var settingsDetail: some View {
    switch activePane {
    case .general:
      generalSettings
    case .menuBar:
      menuBarSettings
    case .appearance:
      appearanceSettings
    case .cleanup:
      cleanupSettings
    case .permissions:
      permissionSettings
    case .about:
      aboutSettings
    }
  }

  private var generalSettings: some View {
    Form {
      Section("Language & Region") {
        Picker("Language", selection: $settings.language) {
          Text("English").tag(AppLanguage.english)
          Text("简体中文").tag(AppLanguage.simplifiedChinese)
        }
      }

      Section("Monitoring") {
        Picker("Refresh interval", selection: $settings.refreshInterval) {
          Text("0.5 seconds").tag(0.5)
          Text("1 second").tag(1.0)
          Text("2 seconds").tag(2.0)
          Text("5 seconds").tag(5.0)
        }
        Picker("Temperature", selection: $settings.temperatureUnit) {
          Text("Celsius").tag(TemperatureUnit.celsius)
          Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
        }
      }

      Section {
        Button("Reset All Settings", role: .destructive) {
          confirmsReset = true
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var appearanceSettings: some View {
    Form {
      Section("Window") {
        Picker("Appearance", selection: $settings.appearance) {
          Text("System").tag(AppAppearance.system)
          Text("Light").tag(AppAppearance.light)
          Text("Dark").tag(AppAppearance.dark)
        }
        .pickerStyle(.segmented)

        Toggle("Translucent sidebar", isOn: $settings.sidebarTransparencyEnabled)

        LabeledContent("Sidebar transparency") {
          HStack(spacing: 10) {
            Slider(value: $settings.sidebarTransparency, in: 0...1, step: 0.05)
              .frame(width: 190)
            Text(settings.sidebarTransparency, format: .percent.precision(.fractionLength(0)))
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
        .disabled(!settings.sidebarTransparencyEnabled)
      }

      Section("Colors") {
        Picker("Theme", selection: $settings.themeID) {
          ForEach(ThemePalette.builtIns) { theme in
            HStack {
              HStack(spacing: 2) {
                Circle().fill(theme.cpuColor)
                Circle().fill(theme.memoryColor)
                Circle().fill(theme.diskColor)
                Circle().fill(theme.networkColor)
              }
              .frame(width: 34, height: 8)
              Text(LocalizedStringKey(theme.name))
            }
            .tag(theme.id)
          }
        }
      }

      Section("Dock Icon") {
        HStack(spacing: 18) {
          AppIconChoice(
            style: .minimal,
            title: "Minimal",
            isSelected: settings.appIconStyle == .minimal
          ) {
            settings.appIconStyle = .minimal
          }
          AppIconChoice(
            style: .detailed,
            title: "Detailed",
            isSelected: settings.appIconStyle == .detailed
          ) {
            settings.appIconStyle = .detailed
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var menuBarSettings: some View {
    Form {
      Section("Status Item") {
        Toggle("Show MacScope in menu bar", isOn: $settings.menuBarEnabled)

        Picker("Menu bar display", selection: $settings.menuBarDisplayMode) {
          Text("Icon Only").tag(MenuBarDisplayMode.iconOnly)
          Text("Compact").tag(MenuBarDisplayMode.compact)
        }
        .pickerStyle(.segmented)
        .disabled(!settings.menuBarEnabled)

        LabeledContent("Preview") {
          MenuBarStatusContent(
            snapshot: metrics.snapshot,
            displayMode: settings.menuBarDisplayMode,
            selectedMetrics: settings.menuBarMetrics,
            temperatureUnit: settings.temperatureUnit
          )
          .padding(.horizontal, 9)
          .frame(height: 28)
          .background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!settings.menuBarEnabled)
      }

      Section("Menu Bar Values") {
        LabeledContent("Selected") {
          Text("\(settings.menuBarMetrics.count) / 3")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        ForEach(settings.orderedMenuBarMetrics) { metric in
          let isSelected = settings.menuBarMetrics.contains(metric)
          MenuBarConfigurationRow(
            title: LocalizedStringKey(metric.title),
            systemImage: metric.systemImage,
            isSelected: Binding(
              get: { settings.menuBarMetrics.contains(metric) },
              set: { settings.setMenuBarMetric(metric, isEnabled: $0) }
            ),
            canSelect: isSelected || settings.menuBarMetrics.count < 3,
            canMoveUp: settings.menuBarMetrics.first != metric && isSelected,
            canMoveDown: settings.menuBarMetrics.last != metric && isSelected,
            moveUp: { settings.moveMenuBarMetric(metric, offset: -1) },
            moveDown: { settings.moveMenuBarMetric(metric, offset: 1) }
          )
        }
      }
      .disabled(!settings.menuBarEnabled || settings.menuBarDisplayMode == .iconOnly)

      Section("Dashboard") {
        Toggle("Colorful mode", isOn: $settings.menuBarColorfulMode)

        ForEach(settings.orderedMenuBarModules) { module in
          let isSelected = settings.menuBarModules.contains(module)
          MenuBarConfigurationRow(
            title: LocalizedStringKey(module.title),
            systemImage: module.systemImage,
            isSelected: Binding(
              get: { settings.menuBarModules.contains(module) },
              set: { settings.setMenuBarModule(module, isEnabled: $0) }
            ),
            canSelect: true,
            canMoveUp: settings.menuBarModules.first != module && isSelected,
            canMoveDown: settings.menuBarModules.last != module && isSelected,
            moveUp: { settings.moveMenuBarModule(module, offset: -1) },
            moveDown: { settings.moveMenuBarModule(module, offset: 1) }
          )
        }
      }
      .disabled(!settings.menuBarEnabled)

      if settings.menuBarModules.contains(.processes) {
        Section("Top Processes") {
          Picker("Process sorting", selection: $settings.menuBarProcessSort) {
            ForEach(MenuBarProcessSort.allCases) { sort in
              Text(LocalizedStringKey(sort.title)).tag(sort)
            }
          }
          Picker("Process count", selection: $settings.menuBarProcessLimit) {
            Text("3").tag(3)
            Text("5").tag(5)
            Text("8").tag(8)
            Text("10").tag(10)
          }
        }
        .disabled(!settings.menuBarEnabled)
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var cleanupSettings: some View {
    Form {
      Section("Cleanup Behavior") {
        Picker("Cache files", selection: $settings.cacheCleanupMode) {
          Text("Move to Trash").tag(CacheCleanupMode.trash)
          Text("Delete Permanently").tag(CacheCleanupMode.delete)
        }
        Toggle("Confirm before cleanup", isOn: $settings.confirmsCleanup)
        Picker("Large file threshold", selection: $settings.largeFileThresholdMB) {
          Text("100 MB").tag(100)
          Text("500 MB").tag(500)
          Text("1 GB").tag(1_024)
          Text("5 GB").tag(5_120)
        }
        Picker("Duplicate minimum size", selection: $settings.duplicateMinimumMB) {
          Text("1 MB").tag(1)
          Text("10 MB").tag(10)
          Text("100 MB").tag(100)
          Text("500 MB").tag(500)
        }
      }

      Section("Scan Folders") {
        List(settings.scanFolderPaths, id: \.self, selection: $selectedScanFolder) { path in
          HStack(spacing: 8) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            Text(path)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .tag(path)
        }
        .frame(height: 112)

        HStack(spacing: 6) {
          Button(action: addScanFolders) {
            Image(systemName: "plus")
          }
          .help("Add Scan Folder")
          Button(action: removeSelectedScanFolder) {
            Image(systemName: "minus")
          }
          .help("Remove Scan Folder")
          .disabled(selectedScanFolder == nil || settings.scanFolderPaths.count <= 1)
          Spacer()
        }
      }

    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var permissionSettings: some View {
    Form {
      Section("Startup") {
        Toggle(
          "Launch MacScope at Login",
          isOn: Binding(
            get: { permissionManager.launchesAtLogin },
            set: { permissionManager.setLaunchesAtLogin($0) }
          )
        )
        .disabled(permissionManager.isUpdatingLoginItem || permissionManager.loginItemState == .unavailable)

        LabeledContent("Status") {
          Label(
            LocalizedStringKey(loginItemStatusTitle),
            systemImage: loginItemStatusImage
          )
          .foregroundStyle(loginItemStatusColor)
        }

        if permissionManager.loginItemState == .requiresApproval {
          Button(action: permissionManager.openLoginItemsSettings) {
            Label("Open Login Items", systemImage: "arrow.up.forward.app")
          }
        }

        if permissionManager.loginItemState == .unavailable {
          Text("Install MacScope in Applications to manage login startup.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = permissionManager.loginItemError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Files & Folders") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "Controls access to Desktop, Documents, and Downloads when they are used as scan folders."
          )
          .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 6) {
            permissionInstruction(1, "Open Files & Folders settings.")
            permissionInstruction(2, "Turn on the folders MacScope needs to scan.")
            permissionInstruction(3, "Return to MacScope and scan again.")
          }

          Button(action: SystemPermission.openFilesAndFoldersSettings) {
            Label("Open Files & Folders Settings", systemImage: "arrow.up.forward.app")
          }
        }
      }

      Section("Full Disk Access") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Allow MacScope to scan protected cleanup files and application leftovers.")
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 6) {
            permissionInstruction(1, "Open Full Disk Access settings.")
            permissionInstruction(2, "Turn on the switch next to MacScope.")
            permissionInstruction(
              3,
              "If the switch is already on, remove MacScope with the minus button, then add /Applications/MacScope.app again with the plus button."
            )
            permissionInstruction(4, "Quit and reopen MacScope.")
          }

          Button(action: SystemPermission.openFullDiskAccessSettings) {
            Label("Open Full Disk Access Settings", systemImage: "arrow.up.forward.app")
          }
          .buttonStyle(.borderedProminent)
        }
      }

      Section("On-Demand Authorization") {
        HStack(spacing: 10) {
          Image(systemName: "person.badge.key")
            .foregroundStyle(.secondary)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 2) {
            Text("Administrator Authorization")
            Text(
              "MacScope requests the standard macOS administrator dialog immediately before a protected operation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Text("Requested When Needed")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .onAppear(perform: permissionManager.refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in permissionManager.refresh()
    }
  }

  private func permissionInstruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(String(number))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .trailing)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var loginItemStatusTitle: String {
    switch permissionManager.loginItemState {
    case .disabled: "Disabled"
    case .enabled: "Enabled"
    case .requiresApproval: "Requires Approval"
    case .unavailable: "Unavailable"
    }
  }

  private var loginItemStatusImage: String {
    switch permissionManager.loginItemState {
    case .disabled: "circle"
    case .enabled: "checkmark.circle.fill"
    case .requiresApproval: "exclamationmark.circle.fill"
    case .unavailable: "xmark.circle.fill"
    }
  }

  private var loginItemStatusColor: Color {
    switch permissionManager.loginItemState {
    case .disabled: .secondary
    case .enabled: .green
    case .requiresApproval: .orange
    case .unavailable: .red
    }
  }

  private var aboutSettings: some View {
    Form {
      Section {
        HStack(spacing: 14) {
          Image(
            nsImage: AppIconController.image(for: settings.appIconStyle)
              ?? NSApp.applicationIconImage
          )
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 64, height: 64)
          VStack(alignment: .leading, spacing: 4) {
            Text("MacScope")
              .font(.title2.weight(.semibold))
            Text("Version \(AppMetadata.version) (\(AppMetadata.build))")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
        .padding(.vertical, 6)
      }

      Section("Developer Homepage") {
        Link(destination: AppLinks.author) {
          GitHubLinkLabel(title: "Author: shenmuoso")
        }
      }

      Section("Help & Information") {
        Button {
          openWindow(id: "help")
        } label: {
          Label("MacScope Help", systemImage: "questionmark.circle")
        }
        Button(action: AppLinks.openGitHub) {
          GitHubLinkLabel(title: "View Project on GitHub")
        }
        Button(action: AppLinks.openNewIssue) {
          GitHubLinkLabel(title: "Report an Issue")
        }
        Button {
          AboutPanel.show(language: settings.language)
        } label: {
          Label("About MacScope", systemImage: "info.circle")
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private func addScanFolders() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    var paths = settings.scanFolderPaths
    for url in panel.urls where !paths.contains(url.path) {
      paths.append(url.path)
    }
    settings.scanFolderPaths = paths
  }

  private func removeSelectedScanFolder() {
    guard let selectedScanFolder, settings.scanFolderPaths.count > 1 else { return }
    settings.scanFolderPaths.removeAll { $0 == selectedScanFolder }
    self.selectedScanFolder = nil
  }
}

private struct MenuBarConfigurationRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  @Binding var isSelected: Bool
  let canSelect: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let moveUp: () -> Void
  let moveDown: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Toggle(isOn: $isSelected) {
        Label(title, systemImage: systemImage)
      }
      .toggleStyle(.checkbox)
      .disabled(!canSelect)

      Spacer()

      Button(action: moveUp) {
        Image(systemName: "chevron.up")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .help("Move Up")
      .disabled(!canMoveUp)

      Button(action: moveDown) {
        Image(systemName: "chevron.down")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .help("Move Down")
      .disabled(!canMoveDown)
    }
  }
}

private struct AppIconChoice: View {
  let style: AppIconStyle
  let title: LocalizedStringKey
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        Image(nsImage: AppIconController.image(for: style) ?? NSApp.applicationIconImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 58, height: 58)

        Label {
          Text(title)
            .foregroundStyle(.primary)
        } icon: {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .font(.callout)
      }
      .frame(width: 116, height: 92)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.22),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
