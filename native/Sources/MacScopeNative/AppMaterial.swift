import AppKit
import SwiftUI

enum AppMaterialRole: Equatable {
  case sidebar
  case toolbar
  case sheet
  case menuBar

  var frostedMaterial: NSVisualEffectView.Material {
    switch self {
    case .sidebar: .sidebar
    case .toolbar: .headerView
    case .sheet: .sheet
    case .menuBar: .popover
    }
  }
}

enum AppMaterialKind: Equatable {
  case nativeSidebar
  case regularGlass
  case frosted
  case opaque
}

enum AppMaterialPolicy {
  static func readingSurfaceOpacity(style: LiquidGlassStyle, isDark: Bool) -> CGFloat {
    switch style {
    case .glass: isDark ? 0.36 : 0
    case .balanced: isDark ? 0.48 : 0.18
    case .frosted: 0
    }
  }

  static func resolve(
    role: AppMaterialRole,
    style: LiquidGlassStyle,
    isEnabled: Bool = true,
    reduceTransparency: Bool,
    increaseContrast: Bool
  ) -> AppMaterialKind {
    guard isEnabled, !reduceTransparency, !increaseContrast else { return .opaque }
    if role == .toolbar { return .opaque }
    if #available(macOS 26.0, *), style != .frosted {
      if role == .sidebar { return .nativeSidebar }
      return .regularGlass
    }
    return .frosted
  }
}

extension View {
  func appSplitWindowStyle() -> some View {
    modifier(AppSplitWindowStyleModifier())
  }

  func appSidebarBackground() -> some View {
    background {
      Color.clear
        .appMaterial(.sidebar)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
  }

  func appDetailBackground() -> some View {
    clipped()
      .background {
        Color(nsColor: .windowBackgroundColor)
          .ignoresSafeArea(edges: .vertical)
          .allowsHitTesting(false)
      }
  }

  func appMaterial(_ role: AppMaterialRole, cornerRadius: CGFloat = 0) -> some View {
    modifier(AppMaterialModifier(role: role, cornerRadius: cornerRadius))
  }

  func appSheetMaterial() -> some View {
    modifier(AppSheetMaterialModifier())
  }
}

private struct AppSplitWindowStyleModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content
        .toolbarBackground(.hidden, for: .windowToolbar)
        .containerBackground(for: .window) {
          Color.clear
        }
    } else {
      content
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
  }
}

private struct AppMaterialModifier: ViewModifier {
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var colorScheme

  let role: AppMaterialRole
  let cornerRadius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    let kind = AppMaterialPolicy.resolve(
      role: role,
      style: settings.liquidGlassStyle,
      isEnabled: role != .sidebar || settings.sidebarTransparencyEnabled,
      reduceTransparency: reduceTransparency,
      increaseContrast: contrast == .increased
    )
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if kind == .nativeSidebar {
      // NavigationSplitView already supplies glass. Another material here makes it opaque.
      content.background {
        Color(nsColor: .windowBackgroundColor)
          .opacity(settings.liquidGlassStyle == .balanced ? 0.18 : 0)
      }
    } else if #available(macOS 26.0, *), kind == .regularGlass {
      content
        .background(
          Color(nsColor: .windowBackgroundColor)
            .opacity(AppMaterialPolicy.readingSurfaceOpacity(
              style: settings.liquidGlassStyle, isDark: colorScheme == .dark)),
          in: shape
        )
        .glassEffect(.regular, in: shape)
    } else if kind == .opaque {
      content.background(Color(nsColor: .windowBackgroundColor), in: shape)
    } else {
      content.background {
        FrostedMaterialView(role: role, style: settings.liquidGlassStyle, cornerRadius: cornerRadius)
          .allowsHitTesting(false)
      }
    }
  }
}

private struct AppSheetMaterialModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content
        .appMaterial(.sheet, cornerRadius: 16)
        .presentationBackground(.clear)
    } else {
      content.appMaterial(.sheet, cornerRadius: 12)
    }
  }
}

private struct FrostedMaterialView: NSViewRepresentable {
  let role: AppMaterialRole
  let style: LiquidGlassStyle
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NativeFrostedMaterialView {
    let view = NativeFrostedMaterialView()
    view.update(role: role, style: style)
    view.wantsLayer = true
    view.layer?.cornerRadius = cornerRadius
    view.layer?.masksToBounds = cornerRadius > 0
    return view
  }

  func updateNSView(_ view: NativeFrostedMaterialView, context: Context) {
    view.update(role: role, style: style)
    view.layer?.cornerRadius = cornerRadius
    view.layer?.masksToBounds = cornerRadius > 0
  }
}

final class NativeFrostedMaterialView: NSVisualEffectView {
  private let tintView = NSView()
  private var tintOpacity: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    blendingMode = .behindWindow
    tintView.wantsLayer = true
    tintView.frame = bounds
    tintView.autoresizingMask = [.width, .height]
    addSubview(tintView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(role: AppMaterialRole, style: LiquidGlassStyle) {
    material = role.frostedMaterial
    state = role == .menuBar ? .active : .followsWindowActiveState
    switch style {
    case .glass: tintOpacity = 0
    case .balanced: tintOpacity = 0.12
    case .frosted: tintOpacity = 0.24
    }
    updateTint()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTint()
  }

  private func updateTint() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tintView.layer?.backgroundColor =
        NSColor.windowBackgroundColor.withAlphaComponent(tintOpacity).cgColor
    }
  }
}

@MainActor
final class OpaqueAppMaterialView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    updateBackgroundColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
  }
}
