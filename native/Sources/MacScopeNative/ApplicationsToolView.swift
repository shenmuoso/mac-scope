import AppKit
import SwiftUI

struct ApplicationsToolView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  @State private var searchText = ""
  @State private var selection: ApplicationRecord.ID?
  @State private var uninstallRecord: ApplicationRecord?

  private var filteredApplications: [ApplicationRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return store.applications }
    return store.applications.filter { record in
      record.application.name.lowercased().contains(query)
        || record.bundleIdentifier.lowercased().contains(query)
        || record.application.url.path.lowercased().contains(query)
    }
  }

  private var selectedRecord: ApplicationRecord? {
    guard let selection else { return nil }
    return store.applications.first { $0.id == selection }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .applications)

      if store.applications.isEmpty, store.activity?.tool == .applications {
        MaintenanceActivityProminentView(tool: .applications)
      } else {
        if store.activity?.tool == .applications {
          MaintenanceActivityInlineView(tool: .applications)
          Divider()
        }

        if store.applications.isEmpty {
          SystemToolEmptyView(
            systemImage: store.scannedTools.contains(.applications) ? "checkmark.circle" : "app.dashed",
            title: store.scannedTools.contains(.applications) ? "No Applications Found" : "Ready to Scan",
            message: store.scannedTools.contains(.applications)
              ? "No applications were found in the standard application folders."
              : "Scan the standard application folders and related user data."
          ) {
            Button(action: store.scanApplications) {
              Label("Scan Applications", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
          }
        } else {
          applicationTable
          Divider()
          SystemToolStatusBar(summary: applicationSummary) {
            if let selectedRecord {
              Text(DisplayFormat.bytes(selectedRecord.totalSize))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
        }
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search Applications")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button(action: store.scanApplications) {
          Label("Scan", systemImage: "arrow.clockwise")
        }
        .help("Scan Applications")
        .disabled(store.isBusy)

        Button(action: beginUninstall) {
          Label("Uninstall", systemImage: "trash")
        }
        .help("Uninstall")
        .disabled(selectedRecord == nil || store.isBusy)
      }
    }
    .onChange(of: store.applications.map(\.id)) { ids in
      if let selection, !ids.contains(selection) {
        self.selection = nil
      }
    }
    .sheet(item: $uninstallRecord) { record in
      ApplicationUninstallView(record: record)
        .environmentObject(store)
    }
  }

  private var applicationTable: some View {
    Table(filteredApplications, selection: $selection) {
      TableColumn("Application") { record in
        HStack(spacing: 9) {
          Image(nsImage: WorkspaceIconCache.icon(for: record.application.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 28, height: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(record.application.name)
              .lineLimit(1)
            if !record.bundleIdentifier.isEmpty {
              Text(record.bundleIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
        .padding(.vertical, 2)
      }
      .width(min: 220, ideal: 320)

      TableColumn("Version") { record in
        Text(record.version.isEmpty ? "—" : record.version)
          .monospacedDigit()
      }
      .width(80)

      TableColumn("App Size") { record in
        Text(DisplayFormat.bytes(record.application.size))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Related Data") { record in
        Text(DisplayFormat.bytes(record.residues.reduce(0) { $0 + $1.size }))
          .monospacedDigit()
      }
      .width(108)

      TableColumn("Copies") { record in
        Text(String(1 + record.otherCopies.count))
          .monospacedDigit()
      }
      .width(64)

      TableColumn("Status") { record in
        if record.isRunning {
          Label("Running", systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        } else {
          Text("Not Running")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .width(94)

      TableColumn("Location") { record in
        Text(record.application.url.deletingLastPathComponent().path)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(record.application.url.path)
      }
      .width(min: 160, ideal: 260)
    }
    .onTapGesture(count: 2, perform: beginUninstall)
    .compactNativeScrollers()
  }

  private var applicationSummary: String {
    let count = filteredApplications.count
    if count == store.applications.count {
      return AppLocalization.string(
        "%lld applications",
        language: settings.language,
        arguments: [Int64(count)]
      )
    }
    return AppLocalization.string(
      "%lld of %lld applications",
      language: settings.language,
      arguments: [Int64(count), Int64(store.applications.count)]
    )
  }

  private func beginUninstall() {
    uninstallRecord = selectedRecord
  }
}

private struct ApplicationUninstallView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  let record: ApplicationRecord

  @State private var selectedIDs: Set<MaintenanceItem.ID>
  @State private var selectedStartupConfigurationIDs: Set<ApplicationStartupConfiguration.ID>

  init(record: ApplicationRecord) {
    self.record = record
    _selectedIDs = State(
      initialValue: Set(
        ([record.application] + record.otherCopies + record.residues).map(\.id)
      )
    )
    _selectedStartupConfigurationIDs = State(
      initialValue: Set(
        record.startupConfigurations.filter {
          $0.isDefaultSelected && $0.canRemove
        }.map(\.id)
      )
    )
  }

  private var currentRecord: ApplicationRecord {
    store.applications.first(where: { $0.id == record.id }) ?? record
  }

  private var copies: [MaintenanceItem] {
    [currentRecord.application] + currentRecord.otherCopies
  }

  private var selectedItems: [MaintenanceItem] {
    (copies + currentRecord.residues).filter { selectedIDs.contains($0.id) }
  }

  private var selectedStartupConfigurations: [ApplicationStartupConfiguration] {
    currentRecord.startupConfigurations.filter {
      selectedStartupConfigurationIDs.contains($0.id)
    }
  }

  private var relatedDataItems: [MaintenanceItem] {
    currentRecord.residues
  }

  private var confirmedStartupConfigurations: [ApplicationStartupConfiguration] {
    currentRecord.startupConfigurations.filter {
      $0.confidence == .confirmed && !$0.isShared
    }
  }

  private var likelyStartupConfigurations: [ApplicationStartupConfiguration] {
    currentRecord.startupConfigurations.filter {
      $0.confidence == .likely && !$0.isShared
    }
  }

  private var sharedStartupConfigurations: [ApplicationStartupConfiguration] {
    currentRecord.startupConfigurations.filter(\.isShared)
  }

  private var allCopiesSelected: Bool {
    copies.allSatisfy { selectedIDs.contains($0.id) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(nsImage: WorkspaceIconCache.icon(for: currentRecord.application.url))
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 54, height: 54)
        VStack(alignment: .leading, spacing: 3) {
          Text("Uninstall \(currentRecord.application.name)")
            .font(.title2.weight(.semibold))
          HStack(spacing: 8) {
            if !currentRecord.version.isEmpty {
              Text("Version \(currentRecord.version)")
            }
            if !currentRecord.bundleIdentifier.isEmpty {
              Text(currentRecord.bundleIdentifier)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)

      Divider()

      if currentRecord.isRunning {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
          Text("The application must be closed before it can be uninstalled.")
            .font(.subheadline)
          Spacer()
          Button("Quit Application") {
            store.quitApplication(currentRecord)
          }
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        Divider()
      }

      List {
        Section("Application") {
          removalRow(currentRecord.application, isSelected: .constant(true), isEnabled: false)
        }

        if !currentRecord.otherCopies.isEmpty {
          Section("Other Installed Copies") {
            ForEach(currentRecord.otherCopies) { copy in
              removalRow(copy, isSelected: copyBinding(copy), isEnabled: true)
            }
          }
        }

        if case .denied = currentRecord.loginItemsAccess {
          Section("Login Items Not Checked") {
            HStack(spacing: 10) {
              Image(systemName: "lock.app.dashed")
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text("Automation access is required to check Open at Login entries for this application.")
                Text("You can still uninstall the application, but its login entry may remain.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("Open Automation Settings") {
                store.openAutomationSettings()
              }
              Button("Check Again") {
                store.scanApplications()
              }
              .disabled(store.isBusy)
            }
          }
        }

        if case .unavailable(let message) = currentRecord.loginItemsAccess {
          Section("Login Items Not Checked") {
            HStack(spacing: 10) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text("MacScope could not check Open at Login entries for this application.")
                Text(verbatim: message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer()
              Button("Check Again") {
                store.scanApplications()
              }
              .disabled(store.isBusy)
            }
          }
        }

        if !confirmedStartupConfigurations.isEmpty {
          Section("Associated Startup Configurations") {
            ForEach(confirmedStartupConfigurations) { configuration in
              startupConfigurationRow(
                configuration,
                isSelected: startupConfigurationBinding(configuration),
                isEnabled: allCopiesSelected && configuration.canRemove
              )
            }
          }
        }

        if !likelyStartupConfigurations.isEmpty {
          Section("Possibly Related Startup Configurations") {
            ForEach(likelyStartupConfigurations) { configuration in
              startupConfigurationRow(
                configuration,
                isSelected: startupConfigurationBinding(configuration),
                isEnabled: allCopiesSelected && configuration.canRemove
              )
            }
          }
        }

        if !sharedStartupConfigurations.isEmpty {
          Section("Shared Background Components") {
            ForEach(sharedStartupConfigurations) { configuration in
              startupConfigurationRow(
                configuration,
                isSelected: .constant(false),
                isEnabled: false
              )
            }
          }
        }

        if !relatedDataItems.isEmpty {
          Section("Related Data") {
            ForEach(relatedDataItems) { residue in
              removalRow(
                residue,
                isSelected: residueBinding(residue),
                isEnabled: allCopiesSelected
              )
            }
          }
        }
      }
      .listStyle(.inset)

      Divider()
      HStack(spacing: 12) {
        Text(localized(
          "%lld files · %lld startup configurations · %@",
          Int64(selectedItems.count),
          Int64(selectedStartupConfigurations.count),
          DisplayFormat.bytes(selectedItems.reduce(0) { $0 + $1.size })
        ))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Uninstall", role: .destructive) {
          store.uninstall(
            currentRecord,
            selectedIDs: selectedIDs,
            selectedStartupConfigurationIDs: selectedStartupConfigurationIDs
          )
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(currentRecord.isRunning)
      }
      .padding(12)
    }
    .frame(width: 720, height: 590)
    .onChange(of: allCopiesSelected) { allSelected in
      if !allSelected {
        selectedIDs.subtract(currentRecord.residues.map(\.id))
        selectedStartupConfigurationIDs.subtract(currentRecord.startupConfigurations.map(\.id))
      }
    }
  }

  private func removalRow(
    _ item: MaintenanceItem,
    isSelected: Binding<Bool>,
    isEnabled: Bool
  ) -> some View {
    HStack(spacing: 10) {
      SelectionCheckbox(isSelected: isSelected, isEnabled: isEnabled)
        .frame(width: 22)
      Image(systemName: removalIcon(for: item.kind))
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(
            item.kind == .application || item.kind == .startupItem
              ? LocalizedStringKey(item.name)
              : LocalizedStringKey(item.category)
          )
            .lineLimit(1)
          if item.id == currentRecord.application.id {
            Text("Required")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(item.url.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.url.path)
      }
      Spacer()
      Text(DisplayFormat.bytes(item.size))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.vertical, 3)
  }

  private func copyBinding(_ item: MaintenanceItem) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(item.id) },
      set: { selected in
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
      }
    )
  }

  private func residueBinding(_ item: MaintenanceItem) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(item.id) },
      set: { selected in
        guard allCopiesSelected else { return }
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
      }
    )
  }

  private func startupConfigurationBinding(
    _ configuration: ApplicationStartupConfiguration
  ) -> Binding<Bool> {
    Binding(
      get: { selectedStartupConfigurationIDs.contains(configuration.id) },
      set: { selected in
        guard allCopiesSelected, configuration.canRemove else { return }
        if selected {
          selectedStartupConfigurationIDs.insert(configuration.id)
        } else {
          selectedStartupConfigurationIDs.remove(configuration.id)
        }
      }
    )
  }

  private func startupConfigurationRow(
    _ configuration: ApplicationStartupConfiguration,
    isSelected: Binding<Bool>,
    isEnabled: Bool
  ) -> some View {
    HStack(spacing: 10) {
      SelectionCheckbox(isSelected: isSelected, isEnabled: isEnabled)
        .frame(width: 22)
      Image(systemName: configuration.source.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Text(verbatim: configuration.name)
            .lineLimit(1)
          Text(configuration.isShared ? "Shared" : configuration.confidence.title)
            .font(.caption2)
            .foregroundStyle(configuration.isShared ? Color.secondary : Color.blue)
        }
        Text(LocalizedStringKey(configuration.evidence))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let targetPath = configuration.targetPath {
          Text(verbatim: targetPath)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(targetPath)
        }
      }
      Spacer()
      Text(configuration.source.title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }

  private func removalIcon(for kind: MaintenanceItemKind) -> String {
    switch kind {
    case .application: "app"
    case .startupItem: "power"
    default: "doc"
    }
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private extension StartupConfigurationSource {
  var title: LocalizedStringKey {
    switch self {
    case .loginItem: "Open at Login"
    case .userLaunchAgent: "User Launch Agent"
    case .globalLaunchAgent: "Global Launch Agent"
    case .systemDaemon: "System Service"
    }
  }

  var systemImage: String {
    switch self {
    case .loginItem: "person.crop.circle.badge.clock"
    case .userLaunchAgent: "person.crop.circle"
    case .globalLaunchAgent: "person.2.circle"
    case .systemDaemon: "gearshape.2"
    }
  }
}

private extension StartupAssociationConfidence {
  var title: LocalizedStringKey {
    switch self {
    case .confirmed: "Confirmed"
    case .likely: "Possible Match"
    }
  }
}
