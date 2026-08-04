import AppKit
import SwiftUI

struct FileCleanupView: View {
  let tool: MaintenanceTool

  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  @State private var selectedIDs = Set<MaintenanceItem.ID>()
  @State private var knownIDs = Set<MaintenanceItem.ID>()
  @State private var confirmsRemoval = false

  private var isDuplicateMode: Bool { tool == .duplicates }

  private var items: [MaintenanceItem] {
    isDuplicateMode ? store.duplicateItems : store.largeFileItems
  }

  private var selectedItems: [MaintenanceItem] {
    items.filter { selectedIDs.contains($0.id) }
  }

  private var selectedSize: UInt64 {
    selectedItems.reduce(0) { $0 + $1.size }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: isDuplicateMode ? .duplicates : .largeFiles)

      if store.activity?.tool == tool {
        MaintenanceActivityInlineView(tool: tool)
        Divider()
      }

      if items.isEmpty, store.activity?.tool == tool, store.isBusy {
        Spacer()
      } else if items.isEmpty {
        emptyState
      } else {
        selectionBar
        Divider()
        fileTable
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: scan) {
          Label("Scan", systemImage: "arrow.clockwise")
        }
        .help(isDuplicateMode ? "Find Duplicates" : "Find Large Files")
        .disabled(store.isBusy)
      }
    }
    .onAppear(perform: synchronizeSelection)
    .onChange(of: items.map(\.id)) { _ in synchronizeSelection() }
    .alert("Move the selected files to Trash?", isPresented: $confirmsRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Move to Trash", role: .destructive, action: performRemoval)
    } message: {
      Text("You can restore these files from Trash until it is emptied.")
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    let hasScanned = store.scannedTools.contains(tool)
    SystemToolEmptyView(
      systemImage: hasScanned
        ? "checkmark.circle"
        : (isDuplicateMode ? "doc.on.doc" : "externaldrive.badge.exclamationmark"),
      title: hasScanned ? "No Files Found" : "Ready to Scan",
      message: emptyMessage(hasScanned: hasScanned)
    ) {
      Button(action: scan) {
        Label(isDuplicateMode ? "Find Duplicates" : "Find Large Files", systemImage: "magnifyingglass")
      }
      .buttonStyle(.borderedProminent)
      .disabled(store.isBusy)
    }
  }

  private var selectionBar: some View {
    HStack(spacing: 12) {
      if isDuplicateMode {
        Text("\(duplicateGroupCount) groups · \(items.count) files")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text("One copy per group is always kept")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("\(items.count) files · \(DisplayFormat.bytes(totalSize))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isDuplicateMode {
        Button("Recommended") { selectRecommendedDuplicates() }
          .buttonStyle(.link)
      } else {
        Button("Select All") { selectedIDs = Set(items.map(\.id)) }
          .buttonStyle(.link)
      }
      Button("Select None") { selectedIDs.removeAll() }
        .buttonStyle(.link)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
  }

  @ViewBuilder
  private var fileTable: some View {
    if isDuplicateMode {
      duplicateTable
    } else {
      largeFileTable
    }
  }

  private var duplicateTable: some View {
    Table(items) {
      TableColumn("") { item in
        SelectionCheckbox(
          isSelected: selectionBinding(for: item),
          isEnabled: canToggle(item)
        )
        .help(canToggle(item) ? "Select for removal" : "At least one copy must be kept")
      }
      .width(34)

      TableColumn("Group") { item in
        Text(item.group)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .width(96)

      TableColumn("Name") { item in
        HStack(spacing: 8) {
          Image(nsImage: WorkspaceIconCache.icon(for: item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
          Text(item.name)
            .lineLimit(1)
        }
      }
      .width(min: 180, ideal: 280)

      TableColumn("Size") { item in
        Text(DisplayFormat.bytes(item.size))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Modified") { item in
        Text(DisplayFormat.date(item.modified))
      }
      .width(110)

      TableColumn("Location") { item in
        Text(item.url.deletingLastPathComponent().path)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.url.path)
      }
      .width(min: 220, ideal: 380)
    }
    .compactNativeScrollers()
  }

  private var largeFileTable: some View {
    Table(items) {
      TableColumn("") { item in
        SelectionCheckbox(isSelected: selectionBinding(for: item))
          .help("Select for removal")
      }
      .width(34)

      TableColumn("Name") { item in
        HStack(spacing: 8) {
          Image(nsImage: WorkspaceIconCache.icon(for: item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
          Text(item.name)
            .lineLimit(1)
        }
      }
      .width(min: 220, ideal: 340)

      TableColumn("Size") { item in
        Text(DisplayFormat.bytes(item.size))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Modified") { item in
        Text(DisplayFormat.date(item.modified))
      }
      .width(110)

      TableColumn("Location") { item in
        Text(item.url.deletingLastPathComponent().path)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.url.path)
      }
      .width(min: 260, ideal: 440)
    }
    .compactNativeScrollers()
  }

  private var totalSize: UInt64 {
    items.reduce(0) { $0 + $1.size }
  }

  private var duplicateGroupCount: Int {
    Set(items.map(\.group)).count
  }

  private func emptyMessage(hasScanned: Bool) -> LocalizedStringKey {
    if hasScanned {
      return isDuplicateMode
        ? "No duplicate files meet the current minimum size."
        : "No files meet the current size threshold."
    }
    return isDuplicateMode
      ? "Compare files in the folders selected in Settings."
      : "Scan the folders selected in Settings."
  }

  private func scan() {
    if isDuplicateMode {
      store.scanDuplicates(settings: settings)
    } else {
      store.scanLargeFiles(settings: settings)
    }
  }

  private func selectionBinding(for item: MaintenanceItem) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(item.id) },
      set: { isSelected in
        if isSelected {
          guard canSelectDuplicate(item) else { return }
          selectedIDs.insert(item.id)
        } else {
          selectedIDs.remove(item.id)
        }
      }
    )
  }

  private func canToggle(_ item: MaintenanceItem) -> Bool {
    selectedIDs.contains(item.id) || canSelectDuplicate(item)
  }

  private func canSelectDuplicate(_ item: MaintenanceItem) -> Bool {
    guard isDuplicateMode else { return true }
    let group = items.filter { $0.group == item.group }
    let selectedCount = group.filter { selectedIDs.contains($0.id) }.count
    return selectedCount < max(0, group.count - 1)
  }

  private func synchronizeSelection() {
    let current = Set(items.map(\.id))
    let added = current.subtracting(knownIDs)
    selectedIDs.formIntersection(current)
    if isDuplicateMode, !added.isEmpty {
      for group in Dictionary(grouping: items, by: \.group).values {
        guard group.contains(where: { added.contains($0.id) }) else { continue }
        selectedIDs.subtract(group.map(\.id))
        selectedIDs.formUnion(group.dropFirst().map(\.id))
      }
    }
    knownIDs = current
  }

  private func selectRecommendedDuplicates() {
    selectedIDs.removeAll()
    for group in Dictionary(grouping: items, by: \.group).values {
      selectedIDs.formUnion(group.dropFirst().map(\.id))
    }
  }

  private func requestRemoval() {
    if settings.confirmsCleanup {
      confirmsRemoval = true
    } else {
      performRemoval()
    }
  }

  private func performRemoval() {
    if isDuplicateMode {
      store.removeDuplicates(selectedItems, settings: settings)
    } else {
      store.removeLargeFiles(selectedItems, settings: settings)
    }
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
