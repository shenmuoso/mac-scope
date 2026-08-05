import AppKit
import SwiftUI

private enum HelpTopic: String, CaseIterable, Identifiable {
  case overview
  case processes
  case tools
  case permissions
  case project

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .overview: "Getting Started"
    case .processes: "Process Management"
    case .tools: "Maintenance Tools"
    case .permissions: "Privacy & Permissions"
    case .project: "Open Source"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .processes: "list.bullet.rectangle"
    case .tools: "wrench.and.screwdriver"
    case .permissions: "hand.raised"
    case .project: "chevron.left.forwardslash.chevron.right"
    }
  }
}

private struct HelpItem {
  let systemImage: String
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
}

struct HelpView: View {
  @EnvironmentObject private var settings: AppSettings
  @State private var selection: HelpTopic? = .overview

  var body: some View {
    NavigationSplitView {
      List(HelpTopic.allCases, selection: $selection) { topic in
        Label(topic.title, systemImage: topic.systemImage)
          .tag(topic)
      }
      .listStyle(.sidebar)
      .compactNativeScrollers()
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
    } detail: {
      topicContent(selection ?? .overview)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(AppLocalization.string("MacScope Help", language: settings.language))
  }

  @ViewBuilder
  private func topicContent(_ topic: HelpTopic) -> some View {
    if topic == .project {
      projectPage
    } else {
      HelpTopicPage(
        title: topic.title,
        subtitle: subtitle(for: topic),
        items: items(for: topic),
        action: topic == .permissions ? AnyView(permissionAction) : nil
      )
    }
  }

  private var projectPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Image(
          nsImage: AppIconController.image(for: settings.appIconStyle)
            ?? NSApp.applicationIconImage
        )
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 72, height: 72)
        Text("MacScope")
          .font(.title2.weight(.semibold))
        Text("MacScope is open source. Visit the repository for source code, releases, and issue tracking.")
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("github.com/shenmuoso/mac-scope")
          .font(.callout.monospaced())
          .textSelection(.enabled)
        Link(destination: AppLinks.github) {
          GitHubLinkLabel(title: "View Project on GitHub")
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: 620, alignment: .leading)
      .padding(28)
    }
    .compactNativeScrollers()
  }

  private var permissionAction: some View {
    Button(action: SystemPermission.openFullDiskAccessSettings) {
      Label("Open Full Disk Access", systemImage: "lock.open")
    }
  }

  private func subtitle(for topic: HelpTopic) -> LocalizedStringKey {
    switch topic {
    case .overview:
      "Understand live system activity at a glance."
    case .processes:
      "Inspect and manage the processes using your Mac."
    case .tools:
      "Review files before MacScope performs a destructive action."
    case .permissions:
      "MacScope requests access only when a selected operation requires it."
    case .project:
      ""
    }
  }

  private func items(for topic: HelpTopic) -> [HelpItem] {
    switch topic {
    case .overview:
      return [
        HelpItem(
          systemImage: "cpu",
          title: "System Metrics",
          detail: "CPU, memory, disk, and network values update automatically."
        ),
        HelpItem(
          systemImage: "chart.xyaxis.line",
          title: "Activity History",
          detail: "Recent system charts make short spikes and sustained activity easier to compare."
        ),
        HelpItem(
          systemImage: "pause.fill",
          title: "Pause and Refresh",
          detail: "Pause monitoring to hold the current values, or refresh immediately from the toolbar."
        ),
      ]
    case .processes:
      return [
        HelpItem(
          systemImage: "magnifyingglass",
          title: "Find a Process",
          detail: "Search by process name or PID, then select a row to enable process actions."
        ),
        HelpItem(
          systemImage: "chart.xyaxis.line",
          title: "Inspect Activity",
          detail: "Process Info shows recent CPU, memory, disk, and network history."
        ),
        HelpItem(
          systemImage: "xmark.circle",
          title: "Quit Safely",
          detail: "Try Quit Process first. Force Quit is reserved for a process that does not respond."
        ),
      ]
    case .tools:
      return [
        HelpItem(
          systemImage: "magnifyingglass",
          title: "Scan Before Removing",
          detail: "Scans do not remove data. Review the discovered paths and selection before continuing."
        ),
        HelpItem(
          systemImage: "trash",
          title: "Recoverable by Default",
          detail: "Applications, related data, large files, and duplicates are moved to Trash by default."
        ),
        HelpItem(
          systemImage: "list.bullet",
          title: "Follow Every Item",
          detail: "Cleanup progress and the result for every selected path remain visible in the tool page."
        ),
      ]
    case .permissions:
      return [
        HelpItem(
          systemImage: "externaldrive.badge.checkmark",
          title: "Full Disk Access",
          detail: "Some Library locations are protected by macOS and require Full Disk Access."
        ),
        HelpItem(
          systemImage: "person.badge.key",
          title: "Administrator Authorization",
          detail: "Protected applications use the standard macOS administrator authorization dialog."
        ),
        HelpItem(
          systemImage: "key.slash",
          title: "Passwords Stay with macOS",
          detail: "MacScope never displays its own password field and never reads administrator credentials."
        ),
      ]
    case .project:
      return []
    }
  }
}

private struct HelpTopicPage: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let items: [HelpItem]
  let action: AnyView?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.body)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .padding(.bottom, 20)

        Divider()

        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(.tint)
              .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
                .font(.headline)
              Text(item.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.vertical, 14)

          if index < items.count - 1 {
            Divider()
              .padding(.leading, 36)
          }
        }

        if let action {
          Divider()
          action
            .padding(.top, 16)
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
      .padding(28)
    }
    .compactNativeScrollers()
  }
}
