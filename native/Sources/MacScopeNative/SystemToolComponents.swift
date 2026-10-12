import AppKit
import SwiftUI

@MainActor
enum WorkspaceIconCache {
  private static let cache = NSCache<NSString, NSImage>()

  static func icon(for url: URL) -> NSImage {
    let key = url.standardizedFileURL.path as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    cache.setObject(icon, forKey: key)
    return icon
  }
}

enum DetailLayout {
  static let pageInset: CGFloat = 24
  static let groupSpacing: CGFloat = 20
  static let groupInset: CGFloat = 16
  static let cornerRadius: CGFloat = 8
  static let readingWidth: CGFloat = 960
}

extension View {
  func detailGroup(inset: CGFloat = DetailLayout.groupInset) -> some View {
    padding(inset)
      .background { DetailGroupBackground() }
  }

  func detailPageInsets() -> some View {
    padding(.horizontal, DetailLayout.pageInset)
      .padding(.top, 16)
      .padding(.bottom, 24)
  }
}

private struct DetailGroupBackground: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DetailLayout.cornerRadius, style: .continuous)
    shape
      .fill(Color(nsColor: .windowBackgroundColor))
      .overlay {
        shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
      }
      .overlay {
        if contrast == .increased {
          shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
        }
      }
  }
}

struct DetailWorkspace<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .detailGroup(inset: 0)
    .clipShape(RoundedRectangle(cornerRadius: DetailLayout.cornerRadius, style: .continuous))
    .detailPageInsets()
  }
}

struct DetailDivider: View {
  var body: some View {
    Divider()
      .padding(.horizontal, DetailLayout.groupInset)
  }
}

struct SystemToolEmptyView<Action: View>: View {
  let systemImage: String
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  @ViewBuilder let action: Action

  init(
    systemImage: String,
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    @ViewBuilder action: () -> Action
  ) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
    self.action = action()
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 38, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      action
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

struct SelectionCheckbox: View {
  @Binding var isSelected: Bool
  var isEnabled = true

  var body: some View {
    Toggle("", isOn: $isSelected)
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(!isEnabled)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

struct SystemToolStatusBar<Actions: View>: View {
  let summary: String
  @ViewBuilder let actions: Actions

  init(summary: String, @ViewBuilder actions: () -> Actions) {
    self.summary = summary
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Spacer()
      actions
    }
    .padding(.horizontal, DetailLayout.groupInset)
    .frame(minHeight: 46)
  }
}
