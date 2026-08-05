import SwiftUI

private enum StartupItemsSection: String, CaseIterable, Identifiable {
  case loginItems
  case backgroundTasks
  case attention

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .loginItems: "Open at Login"
    case .backgroundTasks: "Background Tasks"
    case .attention: "Needs Attention"
    }
  }
}

private enum StartupConfirmation: Identifiable {
  case removeLoginItem(SystemLoginItem)
  case removeBackgroundItem(StartupItem)
  case disableBackgroundItem(StartupItem)

  var id: String {
    switch self {
    case .removeLoginItem(let item): "login:\(item.id)"
    case .removeBackgroundItem(let item): "remove:\(item.id)"
    case .disableBackgroundItem(let item): "disable:\(item.id)"
    }
  }
}

struct StartupItemsView: View {
  @EnvironmentObject private var store: StartupItemsStore
  @EnvironmentObject private var settings: AppSettings

  @State private var section = StartupItemsSection.loginItems
  @State private var searchText = ""
  @State private var loginSelection: SystemLoginItem.ID?
  @State private var backgroundSelection: StartupItem.ID?
  @State private var confirmation: StartupConfirmation?

  private var filteredLoginItems: [SystemLoginItem] {
    let query = normalizedSearch
    guard !query.isEmpty else { return store.loginItems }
    return store.loginItems.filter {
      $0.name.lowercased().contains(query)
        || $0.path?.lowercased().contains(query) == true
    }
  }

  private var filteredBackgroundItems: [StartupItem] {
    let query = normalizedSearch
    guard !query.isEmpty else { return store.backgroundItems }
    return store.backgroundItems.filter { item in
      item.name.lowercased().contains(query)
        || item.label.lowercased().contains(query)
        || item.ownerName?.lowercased().contains(query) == true
        || item.ownerBundleIdentifier?.lowercased().contains(query) == true
        || item.plistURL.path.lowercased().contains(query)
        || item.executableURL?.path.lowercased().contains(query) == true
    }
  }

  private var filteredAttentionLoginItems: [SystemLoginItem] {
    let query = normalizedSearch
    guard !query.isEmpty else { return store.attentionLoginItems }
    return store.attentionLoginItems.filter {
      $0.name.lowercased().contains(query)
        || $0.path?.lowercased().contains(query) == true
    }
  }

  private var filteredAttentionBackgroundItems: [StartupItem] {
    let attentionIDs = Set(store.attentionBackgroundItems.map(\.id))
    return filteredBackgroundItems.filter { attentionIDs.contains($0.id) }
  }

  private var normalizedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var selectedLoginItem: SystemLoginItem? {
    guard let loginSelection else { return nil }
    return store.loginItems.first { $0.id == loginSelection }
  }

  private var selectedBackgroundItem: StartupItem? {
    guard let backgroundSelection else { return nil }
    return store.backgroundItems.first { $0.id == backgroundSelection }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .startupItems)
      sectionBar
      Divider()

      if store.isScanning, !store.hasScanned {
        scanningView
      } else {
        switch section {
        case .loginItems:
          loginItemsContent
        case .backgroundTasks:
          backgroundTasksContent
        case .attention:
          attentionContent
        }
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search Startup Items")
    .toolbar { toolbarContent }
    .onAppear {
      if !store.hasScanned { store.scan() }
    }
    .onChange(of: store.loginItems.map(\.id)) { ids in
      if let loginSelection, !ids.contains(loginSelection) {
        self.loginSelection = nil
      }
    }
    .onChange(of: store.backgroundItems.map(\.id)) { ids in
      if let backgroundSelection, !ids.contains(backgroundSelection) {
        self.backgroundSelection = nil
      }
    }
    .alert(item: $confirmation, content: confirmationAlert)
    .alert("Startup Item Operation Failed", isPresented: errorBinding) {
      Button("OK", action: store.clearError)
    } message: {
      Text(store.operationError ?? "")
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: store.scan) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh Startup Items")
      .disabled(store.isScanning || store.operationItemID != nil)

      if section == .loginItems {
        Button(action: store.chooseLoginItemApplication) {
          Label("Add Login Item", systemImage: "plus")
        }
        .help("Add Login Item")
        .disabled(store.isScanning || store.operationItemID != nil)

        Button {
          if let selectedLoginItem {
            confirmation = .removeLoginItem(selectedLoginItem)
          }
        } label: {
          Label("Remove Login Item", systemImage: "minus")
        }
        .help("Remove Login Item")
        .disabled(selectedLoginItem == nil || store.operationItemID != nil)
      } else if section == .backgroundTasks {
        Button {
          if let selectedBackgroundItem {
            confirmation = .removeBackgroundItem(selectedBackgroundItem)
          }
        } label: {
          Label("Remove Remnant", systemImage: "trash")
        }
        .help("Remove Startup Remnant")
        .disabled(selectedBackgroundItem?.canRemove != true || store.operationItemID != nil)

        Button(action: revealSelectedBackgroundItem) {
          Label("Reveal in Finder", systemImage: "folder")
        }
        .help("Reveal in Finder")
        .disabled(selectedBackgroundItem == nil)
      }

      Button(action: store.openBackgroundItemsSettings) {
        Label("System Background Permissions", systemImage: "gearshape")
      }
      .help("System Background Permissions")
    }
  }

  private var sectionBar: some View {
    HStack(spacing: 16) {
      Picker("Startup Item Category", selection: $section) {
        ForEach(StartupItemsSection.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 430)

      Spacer()

      if store.isScanning || store.operationItemID != nil {
        ProgressView()
          .controlSize(.small)
      }

      Text(sectionSummary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, 14)
    .frame(height: 50)
    .background(.bar)
  }

  @ViewBuilder
  private var loginItemsContent: some View {
    switch store.loginItemsAccess {
    case .denied:
      permissionView
    case .unavailable(let message):
      SystemToolEmptyView(
        systemImage: "exclamationmark.triangle",
        title: "Login Items Unavailable",
        message: LocalizedStringKey(message)
      ) {
        Button(action: store.scan) {
          Label("Try Again", systemImage: "arrow.clockwise")
        }
      }
    case .available:
      if filteredLoginItems.isEmpty {
        SystemToolEmptyView(
          systemImage: normalizedSearch.isEmpty ? "person.crop.circle.badge.checkmark" : "magnifyingglass",
          title: normalizedSearch.isEmpty ? "No Login Items" : "No Matching Login Items",
          message: normalizedSearch.isEmpty
            ? "No applications are configured to open when you log in."
            : "No login items match the current search."
        ) {
          if normalizedSearch.isEmpty {
            Button(action: store.chooseLoginItemApplication) {
              Label("Add Login Item", systemImage: "plus")
            }
          }
        }
      } else {
        loginItemsTable
        Divider()
        statusBar
      }
    }
  }

  private var loginItemsTable: some View {
    Table(filteredLoginItems, selection: $loginSelection) {
      TableColumn("Application") { item in
        LoginItemIdentityView(item: item)
      }
      .width(min: 220, ideal: 300)

      TableColumn("Login Behavior") { item in
        Text(item.isHidden ? "Open in Background" : "Open Normally")
          .foregroundStyle(.secondary)
      }
      .width(min: 125, ideal: 150)

      TableColumn("Status") { item in
        loginItemStatus(item)
      }
      .width(min: 120, ideal: 145)

      TableColumn("Target") { item in
        Text(item.path ?? String(localized: "Path Not Reported"))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.path ?? String(localized: "macOS did not report this login item's path."))
      }
      .width(min: 250, ideal: 420)
    }
    .id(store.tableIdentity)
    .compactNativeScrollers()
  }

  @ViewBuilder
  private var backgroundTasksContent: some View {
    if filteredBackgroundItems.isEmpty {
      SystemToolEmptyView(
        systemImage: normalizedSearch.isEmpty ? "gearshape.2" : "magnifyingglass",
        title: normalizedSearch.isEmpty ? "No Background Tasks" : "No Matching Background Tasks",
        message: normalizedSearch.isEmpty
          ? "No third-party launch agents or system services were found."
          : "No background tasks match the current search."
      ) {
        Button(action: store.scan) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    } else {
      backgroundItemsTable
      Divider()
      statusBar
    }
  }

  private var backgroundItemsTable: some View {
    Table(filteredBackgroundItems, selection: $backgroundSelection) {
      TableColumn("Software or Service") { item in
        StartupItemIdentityView(item: item)
      }
      .width(min: 230, ideal: 310)

      TableColumn("Startup Mode") { item in
        VStack(alignment: .leading, spacing: 1) {
          Text(item.triggerMode.title)
          Text(item.kind.scopeTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 115, ideal: 140)

      TableColumn("Allow System Startup") { item in
        startupPermissionControl(item)
      }
      .width(min: 125, ideal: 145)

      TableColumn("Current State") { item in
        startupRuntime(item)
      }
      .width(min: 115, ideal: 145)

      TableColumn("Target") { item in
        Text(item.executableURL?.path ?? item.parseIssue ?? "-")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.executableURL?.path ?? item.plistURL.path)
      }
      .width(min: 220, ideal: 360)
    }
    .id(store.tableIdentity)
    .compactNativeScrollers()
  }

  @ViewBuilder
  private var attentionContent: some View {
    if filteredAttentionLoginItems.isEmpty && filteredAttentionBackgroundItems.isEmpty {
      SystemToolEmptyView(
        systemImage: normalizedSearch.isEmpty ? "checkmark.circle" : "magnifyingglass",
        title: normalizedSearch.isEmpty ? "No Startup Issues" : "No Matching Startup Issues",
        message: normalizedSearch.isEmpty
          ? "No missing targets or malformed startup configurations were found."
          : "No startup issues match the current search."
      ) {
        Button(action: store.scan) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    } else {
      List {
        if !filteredAttentionLoginItems.isEmpty {
          Section("Login Item Remnants") {
            ForEach(filteredAttentionLoginItems) { item in
              attentionLoginRow(item)
            }
          }
        }
        if !filteredAttentionBackgroundItems.isEmpty {
          Section("Background Task Remnants") {
            ForEach(filteredAttentionBackgroundItems) { item in
              attentionBackgroundRow(item)
            }
          }
        }
      }
      .listStyle(.inset)
      .compactNativeScrollers()
      Divider()
      statusBar
    }
  }

  private var permissionView: some View {
    SystemToolEmptyView(
      systemImage: "lock.app.dashed",
      title: "Allow Login Item Access",
      message: "MacScope needs Automation access to show and manage the same Open at Login list as System Settings."
    ) {
      HStack {
        Button(action: store.scan) {
          Label("Request Access Again", systemImage: "arrow.clockwise")
        }
        Button(action: store.openAutomationSettings) {
          Label("Open Automation Settings", systemImage: "gearshape")
        }
      }
    }
  }

  private var scanningView: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text("Scanning Startup Items")
        .font(.headline)
      Text("Reading Open at Login items and third-party background tasks.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var statusBar: some View {
    SystemToolStatusBar(summary: overallSummary) {
      if !store.scanIssues.isEmpty {
        Label("Scan Warning", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .help(store.scanIssues.joined(separator: "\n"))
      }
      Button(action: store.openBackgroundItemsSettings) {
        Label("System Background Permissions", systemImage: "gearshape")
      }
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func loginItemStatus(_ item: SystemLoginItem) -> some View {
    switch item.residueState {
    case .none:
      Label("Opens at Login", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .suspected:
      Label("Needs Review", systemImage: "questionmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
    case .confirmed:
      Label("Target Missing", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private func startupPermissionControl(_ item: StartupItem) -> some View {
    if store.operationItemID == item.id {
      ProgressView()
        .controlSize(.small)
    } else if item.permissionState == .requiresApproval {
      Button("Review in Settings", action: store.openBackgroundItemsSettings)
        .controlSize(.small)
    } else if item.canChangePermission {
      Toggle(
        "Allow System Startup",
        isOn: Binding(
          get: { item.permissionState == .allowed },
          set: { allowed in setStartupAllowed(allowed, for: item) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
    } else {
      Text("Unavailable")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func startupRuntime(_ item: StartupItem) -> some View {
    switch item.runtimeState {
    case .running(let pid):
      VStack(alignment: .leading, spacing: 1) {
        Label("Running", systemImage: "circle.fill")
          .foregroundStyle(.green)
        if let pid {
          Text("PID \(pid)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
    case .waiting:
      Text("Waiting for Trigger")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .unloaded:
      Text("Not Loaded")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .disabled:
      Text("Startup Blocked")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .requiresApproval:
      Text("Needs User Approval")
        .font(.caption)
        .foregroundStyle(.orange)
    case .unavailable:
      Text("Configuration Unavailable")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func attentionLoginRow(_ item: SystemLoginItem) -> some View {
    HStack(spacing: 12) {
      LoginItemIdentityView(item: item)
      Spacer()
      Text(item.residueState == .confirmed ? "Target Missing" : "Needs Review")
        .font(.caption)
        .foregroundStyle(item.residueState == .confirmed ? .red : .orange)
      Button("Remove") {
        confirmation = .removeLoginItem(item)
      }
      .controlSize(.small)
    }
    .padding(.vertical, 3)
  }

  private func attentionBackgroundRow(_ item: StartupItem) -> some View {
    HStack(spacing: 12) {
      StartupItemIdentityView(item: item)
      Spacer()
      Text(item.parseIssue.map { String(localized: String.LocalizationValue($0)) }
        ?? (item.residueState == .confirmed ? String(localized: "Target Missing") : String(localized: "Needs Review")))
        .font(.caption)
        .foregroundStyle(item.residueState == .confirmed ? .red : .orange)
      if item.canRemove {
        Button("Remove") {
          confirmation = .removeBackgroundItem(item)
        }
        .controlSize(.small)
      }
    }
    .padding(.vertical, 3)
  }

  private var sectionSummary: String {
    switch section {
    case .loginItems:
      return localized("%lld login items", Int64(filteredLoginItems.count))
    case .backgroundTasks:
      return localized("%lld background tasks", Int64(filteredBackgroundItems.count))
    case .attention:
      return localized(
        "%lld items need attention",
        Int64(filteredAttentionLoginItems.count + filteredAttentionBackgroundItems.count)
      )
    }
  }

  private var overallSummary: String {
    localized(
      "%lld login items · %lld background tasks · %lld need attention",
      Int64(store.loginItems.count),
      Int64(store.backgroundItems.count),
      Int64(store.attentionLoginItems.count + store.attentionBackgroundItems.count)
    )
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.operationError != nil },
      set: { isPresented in
        if !isPresented { store.clearError() }
      }
    )
  }

  private func setStartupAllowed(_ allowed: Bool, for item: StartupItem) {
    if !allowed, item.runtimeState.isRunning {
      confirmation = .disableBackgroundItem(item)
    } else {
      store.setStartupAllowed(allowed, for: item)
    }
  }

  private func confirmationAlert(_ value: StartupConfirmation) -> Alert {
    switch value {
    case .removeLoginItem(let item):
      return Alert(
        title: Text("Stop Opening at Login?"),
        message: Text(localized(
          "%@ will remain installed. This does not close it if it is currently running.",
          item.name
        )),
        primaryButton: .destructive(Text("Remove")) {
          store.removeLoginItem(item)
        },
        secondaryButton: .cancel()
      )
    case .removeBackgroundItem(let item):
      return Alert(
        title: Text("Remove Startup Remnant?"),
        message: Text(item.plistURL.path),
        primaryButton: .destructive(Text("Move to Trash")) {
          store.removeBackgroundItem(item)
        },
        secondaryButton: .cancel()
      )
    case .disableBackgroundItem(let item):
      let message: LocalizedStringKey = item.kind.requiresAdministrator
        ? "This system-wide background task will stop immediately and will not start again automatically. An administrator password is required."
        : "This background task will stop immediately and will not start again automatically."
      return Alert(
        title: Text("Block Startup and Stop Task?"),
        message: Text(message),
        primaryButton: .destructive(Text("Block and Stop")) {
          store.setStartupAllowed(false, for: item)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private func revealSelectedBackgroundItem() {
    guard let selectedBackgroundItem else { return }
    store.reveal(selectedBackgroundItem)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private struct LoginItemIdentityView: View {
  let item: SystemLoginItem

  var body: some View {
    HStack(spacing: 9) {
      Group {
        if let applicationURL = item.applicationURL ?? item.targetURL,
          FileManager.default.fileExists(atPath: applicationURL.path)
        {
          Image(nsImage: WorkspaceIconCache.icon(for: applicationURL))
            .resizable()
            .aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: "app.dashed")
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .padding(4)
        }
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: item.name)
          .lineLimit(1)
        Text(item.path ?? String(localized: "Path Not Reported"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct StartupItemIdentityView: View {
  let item: StartupItem

  var body: some View {
    HStack(spacing: 9) {
      Group {
        if let applicationURL = item.ownerApplicationURL {
          Image(nsImage: WorkspaceIconCache.icon(for: applicationURL))
            .resizable()
            .aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: item.kind.systemImage)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .padding(4)
        }
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: item.name)
            .lineLimit(1)
          if item.residueState != .none {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundStyle(item.residueState == .confirmed ? .red : .orange)
          }
        }
        Text(verbatim: item.label)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.vertical, 2)
  }
}

private extension StartupItemKind {
  var scopeTitle: LocalizedStringKey {
    switch self {
    case .userAgent: "Current User"
    case .globalAgent: "All Users"
    case .daemon: "System Level"
    }
  }

  var systemImage: String {
    switch self {
    case .userAgent: "person.crop.circle.badge.clock"
    case .globalAgent: "person.2.circle"
    case .daemon: "gearshape.2"
    }
  }
}

private extension StartupItemTriggerMode {
  var title: LocalizedStringKey {
    switch self {
    case .continuous: "Continuous"
    case .atLogin: "At Login"
    case .atBoot: "At System Startup"
    case .scheduled: "Scheduled"
    case .onDemand: "On Demand"
    case .manual: "Manual or Unknown"
    }
  }
}
