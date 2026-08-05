import AppKit
import Darwin
import SwiftUI

struct PortToolView: View {
  @EnvironmentObject private var navigation: AppNavigation
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var store = PortInfoStore()

  @State private var searchText = ""
  @State private var transportFilter = "all"
  @State private var selection: PortRecord.ID?
  @State private var confirmsForceQuit = false

  private var filteredRecords: [PortRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return store.records.filter { record in
      let matchesTransport = transportFilter == "all"
        || record.transport.rawValue.lowercased() == transportFilter
      let matchesQuery = query.isEmpty
        || String(record.port).contains(query)
        || String(record.pid).contains(query)
        || record.address.lowercased().contains(query)
        || record.processName.lowercased().contains(query)
        || record.software.name.lowercased().contains(query)
      return matchesTransport && matchesQuery
    }
  }

  private var selectedRecord: PortRecord? {
    guard let selection else { return nil }
    return store.records.first { $0.id == selection }
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .ports)

      if store.isLoading && store.records.isEmpty {
        ProgressView("Reading Listening Ports")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if filteredRecords.isEmpty {
        SystemToolEmptyView(
          systemImage: "network",
          title: store.records.isEmpty ? "No Listening Ports" : "No Matching Ports",
          message: store.records.isEmpty
            ? "No visible TCP or UDP listeners were found."
            : "Change the search or protocol filter."
        ) {
          Button("Refresh", action: store.refresh)
        }
      } else {
        portTable
      }

      Divider()
      SystemToolStatusBar(
        summary: localized("%lld listening ports", Int64(filteredRecords.count))
      ) {
        Button(action: openLocalhost) {
          Label("Open", systemImage: "safari")
        }
        .disabled(selectedRecord?.transport != .tcp)

        Button(action: copyEndpoint) {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(selectedRecord == nil)

        Button(action: inspectProcess) {
          Label("Process Info", systemImage: "info.circle")
        }
        .disabled(selectedRecord == nil)

        Menu {
          Button("Quit Process") {
            if let selectedRecord {
              store.send(signal: SIGTERM, to: selectedRecord)
            }
          }
          Button("Force Quit", role: .destructive) {
            confirmsForceQuit = true
          }
        } label: {
          Label("Process Actions", systemImage: "ellipsis.circle")
        }
        .disabled(selectedRecord == nil)
      }
    }
    .searchable(text: $searchText, prompt: "Search Ports and Software")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Picker("Protocol", selection: $transportFilter) {
          Text("All").tag("all")
          Text("TCP").tag("tcp")
          Text("UDP").tag("udp")
        }
        .pickerStyle(.segmented)
        .frame(width: 170)

        Button(action: store.refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh")
        .disabled(store.isLoading)
      }
    }
    .onAppear(perform: store.refresh)
    .alert("Force quit this process?", isPresented: $confirmsForceQuit) {
      Button("Cancel", role: .cancel) {}
      Button("Force Quit", role: .destructive) {
        if let selectedRecord {
          store.send(signal: SIGKILL, to: selectedRecord)
        }
      }
    } message: {
      Text("Unsaved data in the process may be lost.")
    }
    .alert(
      "The process could not be managed",
      isPresented: Binding(
        get: { !store.errorMessage.isEmpty },
        set: { if !$0 { store.errorMessage = "" } }
      )
    ) {
      Button("OK") { store.errorMessage = "" }
    } message: {
      Text(store.errorMessage)
    }
  }

  private var portTable: some View {
    Table(filteredRecords, selection: $selection) {
      TableColumn("Protocol") { record in
        Text(record.transport.rawValue)
          .font(.caption.monospaced())
      }
      .width(64)

      TableColumn("Port") { record in
        Text(record.port, format: .number.grouping(.never))
          .monospacedDigit()
      }
      .width(72)

      TableColumn("Address") { record in
        Text(record.address)
          .font(.callout.monospaced())
          .lineLimit(1)
      }
      .width(min: 130, ideal: 180)

      TableColumn("Scope") { record in
        Text(scopeTitle(record.scope))
      }
      .width(112)

      TableColumn("Software") { record in
        HStack(spacing: 8) {
          Image(nsImage: softwareIcon(record.software))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
          Text(record.software.name)
            .lineLimit(1)
        }
      }
      .width(min: 160, ideal: 250)

      TableColumn("Process") { record in
        VStack(alignment: .leading, spacing: 1) {
          Text(record.processName)
            .lineLimit(1)
          Text("PID \(record.pid)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 130, ideal: 210)
    }
    .compactNativeScrollers()
  }

  private func scopeTitle(_ scope: PortScope) -> LocalizedStringKey {
    switch scope {
    case .local: "Local Only"
    case .allInterfaces: "All Interfaces"
    case .specific: "Specific Address"
    }
  }

  private func softwareIcon(_ software: SoftwareIdentity) -> NSImage {
    if let bundleURL = software.bundleURL {
      return WorkspaceIconCache.icon(for: bundleURL)
    }
    return NSImage(
      systemSymbolName: "terminal",
      accessibilityDescription: "Process"
    ) ?? NSImage()
  }

  private func openLocalhost() {
    guard let selectedRecord, selectedRecord.transport == .tcp,
      let url = URL(string: "http://127.0.0.1:\(selectedRecord.port)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyEndpoint() {
    guard let selectedRecord else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      "\(selectedRecord.transport.rawValue) \(selectedRecord.address):\(selectedRecord.port)",
      forType: .string
    )
  }

  private func inspectProcess() {
    guard let selectedRecord else { return }
    navigation.inspectProcess(selectedRecord.pid)
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
