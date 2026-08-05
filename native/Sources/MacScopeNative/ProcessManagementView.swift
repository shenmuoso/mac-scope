import AppKit
import Combine
import Darwin
import SwiftUI

private enum ProcessCommand: Identifiable {
  case quit(ProcessRow)
  case forceQuit(ProcessRow)

  var id: String {
    switch self {
    case .quit(let process): "quit-\(process.pid)"
    case .forceQuit(let process): "force-\(process.pid)"
    }
  }

  var process: ProcessRow {
    switch self {
    case .quit(let process), .forceQuit(let process): process
    }
  }

  var signal: Int32 {
    switch self {
    case .quit: SIGTERM
    case .forceQuit: SIGKILL
    }
  }

  var title: String {
    switch self {
    case .quit(let process): "Quit \(process.name)?"
    case .forceQuit(let process): "Force Quit \(process.name)?"
    }
  }

  var actionTitle: String {
    switch self {
    case .quit: "Quit"
    case .forceQuit: "Force Quit"
    }
  }
}

private enum ProcessOriginFilter: String, CaseIterable, Identifiable {
  case all
  case macOSSystem
  case installedSoftware
  case userTool
  case unknown

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .all: "All"
    case .macOSSystem: "System Software or Services"
    case .installedSoftware: "Installed Software"
    case .userTool: "Plug-ins or Tools"
    case .unknown: "Other"
    }
  }

  func includes(_ origin: ProcessOrigin) -> Bool {
    switch self {
    case .all: true
    case .macOSSystem: origin == .macOSSystem
    case .installedSoftware: origin == .installedSoftware
    case .userTool: origin == .userTool
    case .unknown: origin == .unknown
    }
  }
}

struct ProcessManagementView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var navigation: AppNavigation

  @State private var searchText = ""
  @State private var selection: ProcessRow.ID?
  @State private var sortOrder = [
    KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)
  ]
  @State private var pendingCommand: ProcessCommand?
  @State private var operationError: String?
  @State private var showsInspector = false
  @State private var sortsBySoftware = false
  @State private var originFilter = ProcessOriginFilter.all
  @State private var softwareSort = SoftwareSortDescriptor.initial
  @State private var expandedSoftwareIDs = Set<SoftwareIdentity.ID>()

  private var selectedProcess: ProcessRow? {
    guard let pid = selection else { return nil }
    return monitor.processes.first { $0.pid == pid }
  }

  private var filteredProcesses: [ProcessRow] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return monitor.processes.filter { process in
      guard originFilter.includes(process.software.origin) else { return false }
      return query.isEmpty
        || process.name.lowercased().contains(query)
        || String(process.pid).contains(query)
        || process.software.name.lowercased().contains(query)
        || process.software.bundleIdentifier?.lowercased().contains(query) == true
    }
  }

  private var visibleProcesses: [ProcessRow] {
    filteredProcesses.sorted(using: sortOrder)
  }

  private var visibleSoftwareGroups: [SoftwareProcessGroup] {
    softwareSort.sorted(groups: SoftwareProcessGroup.groups(from: filteredProcesses))
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .processes)

      HStack(spacing: 0) {
        VStack(spacing: 0) {
          processHeader
          processContent
          Divider()
          ProcessStatusBar(
            isPaused: monitor.isPaused,
            visibleCount: filteredProcesses.count,
            totalCount: monitor.processes.count
          )
        }
        if showsInspector {
          Divider()
          inspectorPane
            .frame(width: 340)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search Processes and Software")
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: monitor.togglePause) {
          Label(
            monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring",
            systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
          )
        }
        .help(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring")

        Button(action: { monitor.refreshNow() }) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh Now")
        .disabled(monitor.isRefreshing)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          toggleInspector()
        } label: {
          Label("Process Info", systemImage: "info.circle")
        }
        .help("Show Process Info")
        .disabled(selectedProcess == nil)

        Menu {
          Button("Show Process Info") {
            showInspector()
          }
          Divider()
          Button("Quit Process") {
            if let selectedProcess {
              pendingCommand = .quit(selectedProcess)
            }
          }
          Button("Force Quit", role: .destructive) {
            if let selectedProcess {
              pendingCommand = .forceQuit(selectedProcess)
            }
          }
        } label: {
          Label("Process Actions", systemImage: "ellipsis.circle")
        }
        .help("Process Actions")
        .disabled(selectedProcess == nil)

      }
    }
    .onChange(of: selection) { selected in
      monitor.trackProcess(selected)
    }
    .onChange(of: searchText) { _ in
      clearHiddenSelection()
    }
    .onChange(of: originFilter) { _ in
      clearHiddenSelection()
    }
    .onChange(of: navigation.processInspectionRequest) { request in
      handleProcessInspection(request)
    }
    .onReceive(monitor.$processes) { processes in
      if let selection, !processes.contains(where: { $0.pid == selection }) {
        self.selection = nil
        showsInspector = false
        monitor.trackProcess(nil)
      }
      handleProcessInspection(navigation.processInspectionRequest)
    }
    .onAppear {
      handleProcessInspection(navigation.processInspectionRequest)
    }
    .onDisappear {
      monitor.trackProcess(nil)
    }
    .alert(item: $pendingCommand) { command in
      Alert(
        title: Text(command.title),
        message: Text("PID \(command.process.pid)"),
        primaryButton: .destructive(Text(command.actionTitle)) {
          operationError = monitor.send(signal: command.signal, to: command.process)
        },
        secondaryButton: .cancel()
      )
    }
    .alert(
      "The process could not be managed",
      isPresented: Binding(
        get: { operationError != nil },
        set: { if !$0 { operationError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { operationError = nil }
    } message: {
      Text(operationError ?? "")
    }
  }

  @ViewBuilder
  private var processContent: some View {
    if monitor.processes.isEmpty {
      ProcessListStateView(
        systemImage: "list.bullet.rectangle",
        title: "Collecting process activity",
        message: "Reading running processes and their resource activity.",
        isLoading: true
      )
    } else if filteredProcesses.isEmpty {
      ProcessListStateView(
        systemImage: "line.3.horizontal.decrease.circle",
        title: "No Matching Processes",
        message: "No processes match the current search and source filter.",
        isLoading: false
      )
    } else if sortsBySoftware {
      softwareGroups
    } else {
      processTable
    }
  }

  @ViewBuilder
  private var inspectorPane: some View {
    if let selectedProcess {
      ProcessInspectorView(
        process: selectedProcess,
        history: monitor.history(for: selectedProcess.pid),
        theme: settings.activeTheme,
        onClose: { showsInspector = false }
      )
    } else {
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button {
            showsInspector = false
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .help("Close Process Info")
        }
        .padding(12)
        Spacer()
        VStack(spacing: 8) {
          Image(systemName: "info.circle")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Select a process to view its activity.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var processHeader: some View {
    HStack(spacing: 8) {
      Text(dashboardTitle)
        .font(.headline)
      Text(headerSummary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()

      Toggle("Group by Software", isOn: $sortsBySoftware)
        .toggleStyle(.switch)
        .fixedSize()
        .help("Group by Software")

      Menu {
        ForEach(ProcessOriginFilter.allCases) { filter in
          Button {
            originFilter = filter
          } label: {
            if originFilter == filter {
              Label(filter.title, systemImage: "checkmark")
            } else {
              Text(filter.title)
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .frame(width: 16)
          Text(originFilter.title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Spacer(minLength: 0)
        }
        .frame(width: 196, alignment: .leading)
      }
      .help("Process Source")

      if let selectedProcess {
        Text("PID \(selectedProcess.pid)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
  }

  private var processTable: some View {
    Table(visibleProcesses, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Process", value: \.name) { process in
        ProcessIdentityView(process: process)
      }
      .width(min: 220, ideal: 290)

      TableColumn("PID", value: \.pid) { process in
        Text(process.pid, format: .number.grouping(.never))
          .monospacedDigit()
      }
      .width(70)

      TableColumn("CPU", value: \.cpuPercent) { process in
        Text(DisplayFormat.percent(process.cpuPercent))
          .monospacedDigit()
      }
      .width(76)

      TableColumn("Memory", value: \.memoryBytes) { process in
        Text(DisplayFormat.bytes(process.memoryBytes))
          .monospacedDigit()
      }
      .width(100)

      TableColumn("Disk Read", value: \.diskReadRate) { process in
        Text(DisplayFormat.rate(process.diskReadRate))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Disk Write", value: \.diskWriteRate) { process in
        Text(DisplayFormat.rate(process.diskWriteRate))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Download", value: \.networkDownloadRate) { process in
        Text(DisplayFormat.rate(process.networkDownloadRate))
          .monospacedDigit()
      }
      .width(96)

      TableColumn("Upload", value: \.networkUploadRate) { process in
        Text(DisplayFormat.rate(process.networkUploadRate))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Threads", value: \.threadCount) { process in
        Text(process.threadCount, format: .number.grouping(.never))
          .monospacedDigit()
      }
      .width(76)

      TableColumn("Runtime", value: \.runtime) { process in
        Text(DisplayFormat.duration(process.runtime))
          .monospacedDigit()
      }
      .width(90)
    }
    .contextMenu(forSelectionType: ProcessRow.ID.self) { selected in
      if let pid = selected.first,
        let process = monitor.processes.first(where: { $0.pid == pid })
      {
        Button("Show Process Info") {
          selection = pid
          monitor.trackProcess(pid)
          showInspector()
        }
        Divider()
        Button("Quit Process") { pendingCommand = .quit(process) }
        Button("Force Quit", role: .destructive) {
          pendingCommand = .forceQuit(process)
        }
      }
    }
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded {
          guard selectedProcess != nil else { return }
          showInspector()
        }
    )
    .compactNativeScrollers()
  }

  private var softwareGroups: some View {
    SoftwareProcessGroupList(
      groups: visibleSoftwareGroups,
      selection: $selection,
      expandedIDs: $expandedSoftwareIDs,
      sort: $softwareSort,
      onInspect: { process in
        selection = process.pid
        monitor.trackProcess(process.pid)
        showInspector()
      },
      onQuit: { process in
        selection = process.pid
        pendingCommand = .quit(process)
      },
      onForceQuit: { process in
        selection = process.pid
        pendingCommand = .forceQuit(process)
      }
    )
  }

  private var headerSummary: String {
    if sortsBySoftware {
      return AppLocalization.string(
        "%lld software groups",
        language: settings.language,
        arguments: [Int64(visibleSoftwareGroups.count)]
      )
    }
    return AppLocalization.string(
      "%lld processes",
      language: settings.language,
      arguments: [Int64(visibleProcesses.count)]
    )
  }

  private var dashboardTitle: LocalizedStringKey {
    sortsBySoftware ? "Software" : "Processes"
  }

  private func toggleInspector() {
    if showsInspector {
      showsInspector = false
    } else {
      showInspector()
    }
  }

  private func showInspector() {
    guard !showsInspector else { return }
    showsInspector = true
    guard let window = AppWindowActions.mainWindow,
      window.frame.width < 1_180,
      let visibleFrame = window.screen?.visibleFrame
    else {
      return
    }

    var frame = window.frame
    let targetWidth = min(1_180, visibleFrame.width)
    let centeredOrigin = frame.midX - targetWidth / 2
    frame.origin.x = min(
      visibleFrame.maxX - targetWidth,
      max(visibleFrame.minX, centeredOrigin)
    )
    frame.size.width = targetWidth
    window.setFrame(frame, display: true, animate: true)
  }

  private func handleProcessInspection(_ request: ProcessInspectionRequest?) {
    guard let request,
      monitor.processes.contains(where: { $0.pid == request.pid })
    else {
      return
    }
    selection = request.pid
    monitor.trackProcess(request.pid)
    showInspector()
    navigation.completeProcessInspection(request)
  }

  private func clearHiddenSelection() {
    guard let selection,
      !filteredProcesses.contains(where: { $0.pid == selection })
    else {
      return
    }
    self.selection = nil
    showsInspector = false
    monitor.trackProcess(nil)
  }
}

private struct ProcessIdentityView: View {
  let process: ProcessRow

  var body: some View {
    HStack(spacing: 9) {
      SoftwareIcon(software: process.software, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(process.name)
          .lineLimit(1)
          .help(process.name)
        HStack(spacing: 4) {
          if process.software.name.caseInsensitiveCompare(process.name) != .orderedSame {
            Text(process.software.name)
              .lineLimit(1)
            Text("·")
          }
          Text(process.software.origin.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct SoftwareProcessGroupList: View {
  let groups: [SoftwareProcessGroup]
  @Binding var selection: ProcessRow.ID?
  @Binding var expandedIDs: Set<SoftwareIdentity.ID>
  @Binding var sort: SoftwareSortDescriptor
  let onInspect: (ProcessRow) -> Void
  let onQuit: (ProcessRow) -> Void
  let onForceQuit: (ProcessRow) -> Void

  var body: some View {
    VStack(spacing: 0) {
      columnHeader
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(groups) { group in
            DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
              ForEach(sort.sorted(processes: group.processes)) { process in
                processRow(process)
                Divider()
                  .padding(.leading, 64)
              }
            } label: {
              softwareRow(group)
            }
            .padding(.horizontal, 12)
            Divider()
          }
        }
      }
      .compactNativeScrollers()
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 0) {
      sortHeader("Software", field: .name, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      sortHeader("Processes", field: .processCount, alignment: .trailing)
        .frame(width: 74, alignment: .trailing)
      sortHeader("CPU", field: .cpu, alignment: .trailing)
        .frame(width: 76, alignment: .trailing)
      sortHeader("Memory", field: .memory, alignment: .trailing)
        .frame(width: 100, alignment: .trailing)
      sortHeader("Disk I/O", field: .disk, alignment: .trailing)
        .frame(width: 96, alignment: .trailing)
      sortHeader("Network I/O", field: .network, alignment: .trailing)
        .frame(width: 100, alignment: .trailing)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 34)
    .frame(height: 30)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func sortHeader(
    _ title: LocalizedStringKey,
    field: SoftwareSortField,
    alignment: Alignment
  ) -> some View {
    Button {
      sort.select(field)
    } label: {
      HStack(spacing: 4) {
        Text(title)
          .lineLimit(1)
        if sort.field == field {
          Image(systemName: sort.direction == .ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func softwareRow(_ group: SoftwareProcessGroup) -> some View {
    HStack(spacing: 0) {
      HStack(spacing: 9) {
        SoftwareIcon(software: group.software, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(group.software.name)
            .lineLimit(1)
            .help(group.software.name)
          HStack(spacing: 4) {
            Text(group.software.origin.title)
            if let bundleIdentifier = group.software.bundleIdentifier {
              Text("·")
              Text(bundleIdentifier)
                .lineLimit(1)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(group.processes.count, format: .number.grouping(.never))
        .frame(width: 74, alignment: .trailing)
      Text(DisplayFormat.percent(group.cpuPercent))
        .frame(width: 76, alignment: .trailing)
      Text(DisplayFormat.bytes(group.memoryBytes))
        .frame(width: 100, alignment: .trailing)
      Text(DisplayFormat.rate(group.diskRate))
        .frame(width: 96, alignment: .trailing)
      Text(DisplayFormat.rate(group.networkRate))
        .frame(width: 100, alignment: .trailing)
    }
    .monospacedDigit()
    .padding(.vertical, 6)
    .frame(minHeight: 44)
  }

  private func processRow(_ process: ProcessRow) -> some View {
    Button {
      selection = process.pid
    } label: {
      HStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "arrow.turn.down.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 18)
          Text(process.name)
            .lineLimit(1)
          Text("PID \(process.pid)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text("")
          .frame(width: 74)
        Text(DisplayFormat.percent(process.cpuPercent))
          .frame(width: 76, alignment: .trailing)
        Text(DisplayFormat.bytes(process.memoryBytes))
          .frame(width: 100, alignment: .trailing)
        Text(DisplayFormat.rate(process.diskReadRate + process.diskWriteRate))
          .frame(width: 96, alignment: .trailing)
        Text(DisplayFormat.rate(process.networkDownloadRate + process.networkUploadRate))
          .frame(width: 100, alignment: .trailing)
      }
      .padding(.leading, 18)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background(
        selection == process.pid ? Color.accentColor.opacity(0.12) : Color.clear
      )
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded { onInspect(process) }
    )
    .contextMenu {
      Button("Show Process Info") { onInspect(process) }
      Divider()
      Button("Quit Process") { onQuit(process) }
      Button("Force Quit", role: .destructive) { onForceQuit(process) }
    }
  }

  private func expansionBinding(for id: SoftwareIdentity.ID) -> Binding<Bool> {
    Binding(
      get: { expandedIDs.contains(id) },
      set: { isExpanded in
        if isExpanded {
          expandedIDs.insert(id)
        } else {
          expandedIDs.remove(id)
        }
      }
    )
  }
}

private struct SoftwareIcon: View {
  let software: SoftwareIdentity
  let size: CGFloat

  var body: some View {
    Group {
      if let bundleURL = software.bundleURL {
        Image(nsImage: WorkspaceIconCache.icon(for: bundleURL))
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: software.origin.systemImage)
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(software.origin.tintColor)
      }
    }
    .frame(width: size, height: size)
    .help(software.origin.title)
  }
}

private extension ProcessOrigin {
  var title: LocalizedStringKey {
    switch self {
    case .macOSSystem: "System Software or Services"
    case .installedSoftware: "Installed Software"
    case .userTool: "Plug-ins or Tools"
    case .unknown: "Other"
    }
  }

  var systemImage: String {
    switch self {
    case .macOSSystem: "gearshape.2.fill"
    case .installedSoftware: "app.fill"
    case .userTool: "terminal.fill"
    case .unknown: "questionmark.circle"
    }
  }

  var tintColor: Color {
    switch self {
    case .macOSSystem, .unknown: .secondary
    case .installedSoftware: .accentColor
    case .userTool: .orange
    }
  }
}

private struct ProcessStatusBar: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  let isPaused: Bool
  let visibleCount: Int
  let totalCount: Int

  var body: some View {
    HStack {
      if isPaused {
        Label("Monitoring Paused", systemImage: "pause.circle.fill")
          .foregroundStyle(.secondary)
      } else {
        Text("Updated \(metrics.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(summary)
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 28)
  }

  private var summary: String {
    return AppLocalization.string(
      "%lld of %lld processes",
      language: settings.language,
      arguments: [Int64(visibleCount), Int64(totalCount)]
    )
  }
}

private struct ProcessListStateView: View {
  let systemImage: String
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let isLoading: Bool

  var body: some View {
    VStack(spacing: 9) {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .font(.system(size: 30, weight: .light))
          .foregroundStyle(.secondary)
      }
      Text(title)
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
