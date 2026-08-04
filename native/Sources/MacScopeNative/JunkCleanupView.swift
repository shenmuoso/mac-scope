import SwiftUI

struct JunkCleanupView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  @State private var selectedIDs = Set<MaintenanceItem.ID>()
  @State private var knownIDs = Set<MaintenanceItem.ID>()
  @State private var confirmsCleanup = false

  private var selectedItems: [MaintenanceItem] {
    store.junkItems.filter { selectedIDs.contains($0.id) }
  }

  private var selectedSize: UInt64 {
    selectedItems.reduce(0) { $0 + $1.size }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .junk)

      if store.activity?.tool == .junk {
        MaintenanceActivityInlineView(tool: .junk)
        Divider()
      }

      if store.junkItems.isEmpty, store.activity?.tool == .junk, store.isBusy {
        Spacer()
      } else if store.junkItems.isEmpty {
        SystemToolEmptyView(
          systemImage: store.scannedTools.contains(.junk) ? "checkmark.circle" : "trash",
          title: store.scannedTools.contains(.junk) ? "No Junk Found" : "Ready to Scan",
          message: store.scannedTools.contains(.junk)
            ? "The selected locations do not contain removable items."
            : "Scan common user-library locations for removable files."
        ) {
          Button(action: store.scanJunk) {
            Label("Scan for Junk", systemImage: "magnifyingglass")
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isBusy)
        }
      } else {
        selectionBar
        Divider()
        junkTable
        Divider()
        SystemToolStatusBar(
          summary: localized(
            "%lld selected · %@",
            Int64(selectedItems.count),
            DisplayFormat.bytes(selectedSize)
          )
        ) {
          Button("Clean Selected", role: .destructive, action: requestCleanup)
            .disabled(selectedItems.isEmpty || store.isBusy)
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: store.scanJunk) {
          Label("Scan", systemImage: "arrow.clockwise")
        }
        .help("Scan for Junk")
        .disabled(store.isBusy)
      }
    }
    .onAppear(perform: synchronizeSelection)
    .onChange(of: store.junkItems.map(\.id)) { _ in synchronizeSelection() }
    .alert(cleanupTitle, isPresented: $confirmsCleanup) {
      Button("Cancel", role: .cancel) {}
      Button("Clean", role: .destructive, action: performCleanup)
    } message: {
      Text(cleanupMessage)
    }
  }

  private var selectionBar: some View {
    HStack(spacing: 12) {
      Text("\(store.junkItems.count) items · \(DisplayFormat.bytes(totalSize))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Select All") { selectedIDs = Set(store.junkItems.map(\.id)) }
        .buttonStyle(.link)
      Button("Select None") { selectedIDs.removeAll() }
        .buttonStyle(.link)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
  }

  private var junkTable: some View {
    Table(store.junkItems) {
      TableColumn("") { item in
        SelectionCheckbox(isSelected: selectionBinding(for: item.id))
      }
      .width(34)

      TableColumn("Item") { item in
        HStack(spacing: 8) {
          Image(systemName: iconName(for: item.kind))
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text(item.name)
            .lineLimit(1)
        }
      }
      .width(min: 170, ideal: 260)

      TableColumn("Category") { item in
        Text(LocalizedStringKey(item.category))
          .foregroundStyle(.secondary)
      }
      .width(min: 100, ideal: 130)

      TableColumn("Size") { item in
        Text(DisplayFormat.bytes(item.size))
          .monospacedDigit()
      }
      .width(90)

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
      .width(min: 180, ideal: 300)
    }
    .compactNativeScrollers()
  }

  private var totalSize: UInt64 {
    store.junkItems.reduce(0) { $0 + $1.size }
  }

  private var cleanupTitle: String {
    settings.cacheCleanupMode == .delete
      ? localized("Clean the selected items?")
      : localized("Move the selected items to Trash?")
  }

  private var cleanupMessage: String {
    settings.cacheCleanupMode == .delete
      ? localized("Caches and developer files will be deleted permanently. Other items will be moved to Trash.")
      : localized("You can restore these items from Trash until it is emptied.")
  }

  private func iconName(for kind: MaintenanceItemKind) -> String {
    switch kind {
    case .cache: "shippingbox"
    case .log: "doc.text"
    case .diagnostic: "stethoscope"
    case .developer: "hammer"
    default: "doc"
    }
  }

  private func selectionBinding(for id: MaintenanceItem.ID) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(id) },
      set: { isSelected in
        if isSelected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
      }
    )
  }

  private func synchronizeSelection() {
    let current = Set(store.junkItems.map(\.id))
    let added = current.subtracting(knownIDs)
    selectedIDs.formIntersection(current)
    selectedIDs.formUnion(added)
    knownIDs = current
  }

  private func requestCleanup() {
    if settings.confirmsCleanup {
      confirmsCleanup = true
    } else {
      performCleanup()
    }
  }

  private func performCleanup() {
    store.cleanJunk(selectedItems, settings: settings)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
