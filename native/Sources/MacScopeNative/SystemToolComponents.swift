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

struct SystemToolPageHeader: View {
  let destination: AppDestination

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(destination.iconColor.gradient)
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(.white.opacity(0.18), lineWidth: 0.5)
          }

        Image(systemName: destination.systemImage)
          .symbolRenderingMode(.monochrome)
          .font(.system(size: 27, weight: .medium))
          .foregroundStyle(.white)
      }
      .frame(width: 56, height: 56)
      .shadow(color: .black.opacity(0.16), radius: 2, y: 1)

      Text(destination.title)
        .font(.title2.weight(.semibold))

      Text(destination.pageDescription)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 560)
    }
    .frame(maxWidth: .infinity, minHeight: 116)
    .padding(.horizontal, 28)
    .padding(.vertical, 16)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }
    .frame(maxWidth: 880)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 14)
    .accessibilityElement(children: .combine)
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
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(.bar)
  }
}
