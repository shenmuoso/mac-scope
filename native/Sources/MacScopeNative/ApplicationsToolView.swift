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

      if store.activity?.tool == .applications {
        MaintenanceActivityInlineView(tool: .applications)
        Divider()
      }

      if store.applications.isEmpty, store.activity?.tool == .applications, store.isBusy {
        Spacer()
      } else if store.applications.isEmpty {
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
  @Environment(\.dismiss) private var dismiss

  let record: ApplicationRecord

  @State private var selectedIDs: Set<MaintenanceItem.ID>

  init(record: ApplicationRecord) {
    self.record = record
    _selectedIDs = State(
      initialValue: Set(
        ([record.application] + record.otherCopies + record.residues).map(\.id)
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

        if !currentRecord.residues.isEmpty {
          Section("Related Data") {
            ForEach(currentRecord.residues) { residue in
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
        Text("\(selectedItems.count) items · \(DisplayFormat.bytes(selectedItems.reduce(0) { $0 + $1.size }))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Uninstall", role: .destructive) {
          store.uninstall(currentRecord, selectedIDs: selectedIDs)
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
      Image(systemName: item.kind == .application ? "app" : "doc")
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(
            item.kind == .application
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
}
