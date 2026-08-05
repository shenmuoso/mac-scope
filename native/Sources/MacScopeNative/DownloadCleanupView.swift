import SwiftUI

struct DownloadCleanupView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  @State private var selectedIDs = Set<MaintenanceItem.ID>()
  @State private var categoryFilter = "All"
  @State private var searchText = ""
  @State private var confirmsRemoval = false

  private let categories = [
    "All",
    "Duplicate Download",
    "Incomplete Download",
    "Installer",
    "Archive",
    "Large Download",
    "Old Download",
  ]

  private var filteredItems: [MaintenanceItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return store.downloadItems.filter { item in
      (categoryFilter == "All" || item.category == categoryFilter)
        && (query.isEmpty || item.name.lowercased().contains(query))
    }
  }

  private var selectedItems: [MaintenanceItem] {
    store.downloadItems.filter { selectedIDs.contains($0.id) }
  }

  private var selectedSize: UInt64 {
    selectedItems.reduce(0) { $0 + $1.size }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .downloads)

      if store.downloadItems.isEmpty, store.activity?.tool == .downloads {
        MaintenanceActivityProminentView(tool: .downloads)
      } else {
        if store.activity?.tool == .downloads {
          MaintenanceActivityInlineView(tool: .downloads)
          Divider()
        }

        if store.downloadItems.isEmpty {
          emptyState
        } else {
          filterBar
          Divider()
          downloadTable
          Divider()
          SystemToolStatusBar(
            summary: localized(
              "%lld selected · %@",
              Int64(selectedItems.count),
              DisplayFormat.bytes(selectedSize)
            )
          ) {
            Button("Move to Trash", role: .destructive, action: requestRemoval)
              .disabled(selectedItems.isEmpty || store.isBusy)
          }
        }
      }
    }
    .searchable(text: $searchText, prompt: "Search Downloads")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Picker("Older Than", selection: $settings.downloadCleanupAgeDays) {
          Text("7 Days").tag(7)
          Text("30 Days").tag(30)
          Text("90 Days").tag(90)
          Text("180 Days").tag(180)
        }
        .frame(width: 150)

        Button(action: scan) {
          Label("Scan Downloads", systemImage: "magnifyingglass")
        }
        .help("Scan Downloads")
        .disabled(store.isBusy)
      }
    }
    .onChange(of: store.downloadItems.map(\.id)) { ids in
      selectedIDs.formIntersection(ids)
      if categoryFilter != "All",
        !store.downloadItems.contains(where: { $0.category == categoryFilter })
      {
        categoryFilter = "All"
      }
    }
    .alert("Move the selected files to Trash?", isPresented: $confirmsRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Move to Trash", role: .destructive, action: performRemoval)
    } message: {
      Text("You can restore these files from Trash until it is emptied.")
    }
  }

  private var emptyState: some View {
    let hasScanned = store.scannedTools.contains(.downloads)
    return SystemToolEmptyView(
      systemImage: hasScanned ? "checkmark.circle" : "arrow.down.circle",
      title: hasScanned ? "Downloads Are Clear" : "Ready to Scan",
      message: hasScanned
        ? "No downloads match the current cleanup categories."
        : "Scan the Downloads folder without removing any files."
    ) {
      Button(action: scan) {
        Label("Scan Downloads", systemImage: "magnifyingglass")
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.isBusy)
    }
  }

  private var filterBar: some View {
    HStack(spacing: 12) {
      Text(
        localized(
          "%lld files · %@",
          Int64(filteredItems.count),
          DisplayFormat.bytes(filteredItems.reduce(0) { $0 + $1.size })
        )
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      Spacer()

      Button("Recommended", action: selectRecommended)
        .buttonStyle(.link)
      Button("Select All") {
        for item in filteredItems where canSelect(item) {
          selectedIDs.insert(item.id)
        }
      }
      .buttonStyle(.link)
      Button("Select None") { selectedIDs.removeAll() }
        .buttonStyle(.link)

      Picker("Category", selection: $categoryFilter) {
        ForEach(categories, id: \.self) { category in
          Text(LocalizedStringKey(category)).tag(category)
        }
      }
      .frame(width: 190)
    }
    .padding(.horizontal, 14)
    .frame(height: 40)
  }

  private var downloadTable: some View {
    Table(filteredItems) {
      TableColumn("") { item in
        SelectionCheckbox(
          isSelected: selectionBinding(for: item),
          isEnabled: selectedIDs.contains(item.id) || canSelect(item)
        )
        .help(canSelect(item) ? "Select for removal" : "At least one copy must be kept")
      }
      .width(34)

      TableColumn("Category") { item in
        Text(LocalizedStringKey(item.category))
          .foregroundStyle(.secondary)
      }
      .width(150)

      TableColumn("Name") { item in
        HStack(spacing: 8) {
          Image(nsImage: WorkspaceIconCache.icon(for: item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
          Text(item.name)
            .lineLimit(1)
            .help(item.name)
        }
      }
      .width(min: 240, ideal: 400)

      TableColumn("Size") { item in
        Text(DisplayFormat.bytes(item.size))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Modified") { item in
        Text(DisplayFormat.date(item.modified))
      }
      .width(120)
    }
    .compactNativeScrollers()
  }

  private func selectionBinding(for item: MaintenanceItem) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(item.id) },
      set: { isSelected in
        if isSelected {
          guard canSelect(item) else { return }
          selectedIDs.insert(item.id)
        } else {
          selectedIDs.remove(item.id)
        }
      }
    )
  }

  private func canSelect(_ item: MaintenanceItem) -> Bool {
    guard item.category == "Duplicate Download", !item.group.isEmpty else { return true }
    let group = store.downloadItems.filter { $0.group == item.group }
    let selectedCount = group.filter { selectedIDs.contains($0.id) }.count
    return selectedCount < max(0, group.count - 1)
  }

  private func selectRecommended() {
    selectedIDs.removeAll()
    let cutoff = Date().addingTimeInterval(-Double(settings.downloadCleanupAgeDays) * 86_400)

    for item in store.downloadItems {
      if item.category == "Incomplete Download" {
        selectedIDs.insert(item.id)
      } else if (item.category == "Installer" || item.category == "Archive"),
        item.modified < cutoff
      {
        selectedIDs.insert(item.id)
      }
    }

    let duplicateGroups = Dictionary(
      grouping: store.downloadItems.filter { $0.category == "Duplicate Download" },
      by: \.group
    )
    for group in duplicateGroups.values {
      let newestFirst = group.sorted { $0.modified > $1.modified }
      selectedIDs.formUnion(newestFirst.dropFirst().map(\.id))
    }
  }

  private func scan() {
    selectedIDs.removeAll()
    store.scanDownloads(settings: settings)
  }

  private func requestRemoval() {
    if settings.confirmsCleanup {
      confirmsRemoval = true
    } else {
      performRemoval()
    }
  }

  private func performRemoval() {
    store.removeDownloads(selectedItems)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
