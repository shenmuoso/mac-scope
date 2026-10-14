import AppKit
import QuartzCore

@MainActor
final class MenuBarDashboardPanel: NSPanel {
  enum PresentationState {
    case hidden, opening, shown, closing
  }

  private let surfaceView = MenuBarPanelSurfaceView()
  private let trackingView = MenuBarPanelTrackingView()
  private let reduceMotion: @MainActor () -> Bool
  private var materialKind: AppMaterialKind?
  private var transitionID = 0
  private var collapsedTransform = CATransform3DIdentity
  private(set) var presentationState = PresentationState.hidden

  var isPresented: Bool {
    presentationState == .opening || presentationState == .shown
  }

  var onPointerChange: ((Bool) -> Void)? {
    get { trackingView.onPointerChange }
    set { trackingView.onPointerChange = newValue }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(
    reduceMotion: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
  ) {
    self.reduceMotion = reduceMotion
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: MenuBarDashboardLayout.width, height: 500),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .popUpMenu
    hidesOnDeactivate = false
    animationBehavior = .none
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    contentView = surfaceView
    updateMaterial(style: .glass)
  }

  func present(from anchor: NSRect, animated: Bool = true) {
    guard !isPresented else { return }
    let wasVisible = isVisible
    surfaceView.layoutSubtreeIfNeeded()
    guard let layer = surfaceView.layer else { return }
    let scale: CGFloat = 0.12
    let origin = CGPoint(
      x: min(max(anchor.midX - frame.minX, 0), surfaceView.bounds.width),
      y: surfaceView.bounds.height
    )
    let pivot = CGPoint(
      x: origin.x - layer.anchorPoint.x * layer.bounds.width,
      y: origin.y - layer.anchorPoint.y * layer.bounds.height
    )
    collapsedTransform = CATransform3DMakeAffineTransform(CGAffineTransform(
      a: scale, b: 0, c: 0, d: scale,
      tx: pivot.x * (1 - scale), ty: pivot.y * (1 - scale)
    ))
    if !wasVisible {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = reduceMotion() ? CATransform3DIdentity : collapsedTransform
      layer.opacity = 0
      CATransaction.commit()
    }
    presentationState = .opening
    ignoresMouseEvents = false
    makeKeyAndOrderFront(nil)
    animatePresentation(visible: true, animated: animated, fromHidden: !wasVisible)
  }

  func dismiss(animated: Bool = true) {
    guard isVisible else { return }
    guard animated else {
      close()
      return
    }
    guard presentationState != .closing else { return }
    presentationState = .closing
    ignoresMouseEvents = true
    animatePresentation(visible: false, animated: true)
  }

  override func close() {
    transitionID += 1
    presentationState = .hidden
    surfaceView.layer?.removeAnimation(forKey: "menuBarPresentation")
    super.close()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surfaceView.layer?.transform = CATransform3DIdentity
    surfaceView.layer?.opacity = 1
    CATransaction.commit()
    ignoresMouseEvents = false
  }

  private func animatePresentation(visible: Bool, animated: Bool, fromHidden: Bool = false) {
    guard let layer = surfaceView.layer else { return }
    transitionID += 1
    let currentID = transitionID
    let reducedMotion = reduceMotion()
    let current = fromHidden ? layer : (layer.presentation() ?? layer)
    let transform = CABasicAnimation(keyPath: "transform")
    transform.fromValue = NSValue(caTransform3D: current.transform)
    transform.toValue = NSValue(caTransform3D:
      visible || reducedMotion ? CATransform3DIdentity : collapsedTransform)
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = current.opacity
    opacity.toValue = visible ? Float(1) : Float(0)

    // Start reversals at the rendered pose; stale completions must not close a reopened panel.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeAnimation(forKey: "menuBarPresentation")
    layer.transform = visible || reducedMotion ? CATransform3DIdentity : collapsedTransform
    layer.opacity = visible ? 1 : 0
    CATransaction.commit()
    guard animated else {
      finishPresentation(visible: visible, transitionID: currentID)
      return
    }

    let animation = CAAnimationGroup()
    animation.animations = reducedMotion ? [opacity] : [transform, opacity]
    animation.duration = reducedMotion ? 0.12 : (visible ? 0.3 : 0.22)
    animation.timingFunction = visible
      ? CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
      : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.75, 0.35)
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      Task { @MainActor in
        self?.finishPresentation(visible: visible, transitionID: currentID)
      }
    }
    layer.add(animation, forKey: "menuBarPresentation")
    CATransaction.commit()
  }

  private func finishPresentation(visible: Bool, transitionID: Int) {
    guard self.transitionID == transitionID else { return }
    if visible {
      presentationState = .shown
      invalidateShadow()
    } else {
      close()
    }
  }

  func setHostedView(_ view: NSView) {
    view.focusRingType = .none
    view.translatesAutoresizingMaskIntoConstraints = false
    trackingView.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
      view.topAnchor.constraint(equalTo: trackingView.topAnchor),
      view.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor),
    ])
  }

  func updateMaterial(style: LiquidGlassStyle) {
    let kind = AppMaterialPolicy.resolve(
      role: .menuBar,
      style: style,
      reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    )
    guard materialKind != kind else {
      updateReadingSurface(style: style)
      return
    }
    materialKind = kind

    let size = surfaceView.bounds.size
    trackingView.removeFromSuperview()
    surfaceView.subviews.forEach { $0.removeFromSuperview() }
    trackingView.frame = NSRect(origin: .zero, size: size)
    trackingView.translatesAutoresizingMaskIntoConstraints = false
    let materialView: NSView
    if #available(macOS 26.0, *), kind == .regularGlass {
      let glass = NSGlassEffectView(frame: trackingView.frame)
      glass.style = .regular
      glass.cornerRadius = 16
      glass.contentView = trackingView
      materialView = glass
    } else if kind == .opaque {
      let background = OpaqueAppMaterialView(frame: trackingView.frame)
      background.addSubview(trackingView)
      materialView = background
    } else {
      let material = NativeFrostedMaterialView(frame: trackingView.frame)
      material.update(role: .menuBar, style: style)
      material.addSubview(trackingView)
      materialView = material
    }
    materialView.translatesAutoresizingMaskIntoConstraints = false
    surfaceView.addSubview(materialView)
    NSLayoutConstraint.activate([
      materialView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
      materialView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
      materialView.topAnchor.constraint(equalTo: surfaceView.topAnchor),
      materialView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
      trackingView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
      trackingView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
      trackingView.topAnchor.constraint(equalTo: materialView.topAnchor),
      trackingView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),
    ])
    updateReadingSurface(style: style)
    invalidateShadow()
  }

  private func updateReadingSurface(style: LiquidGlassStyle) {
    trackingView.glassStyle = materialKind == .regularGlass ? style : nil
    if let material = surfaceView.subviews.first as? NativeFrostedMaterialView {
      material.update(role: .menuBar, style: style)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    dismiss()
  }
}

@MainActor
private final class MenuBarPanelSurfaceView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.cornerRadius = 16
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    focusRingType = .none
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    window?.invalidateShadow()
  }
}

@MainActor
private final class MenuBarPanelTrackingView: NSView {
  private let readingSurface = NSView()
  var onPointerChange: ((Bool) -> Void)?
  var glassStyle: LiquidGlassStyle? {
    didSet { updateReadingSurface() }
  }
  private var pointerTrackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    readingSurface.wantsLayer = true
    readingSurface.frame = bounds
    readingSurface.autoresizingMask = [.width, .height]
    addSubview(readingSurface, positioned: .below, relativeTo: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateReadingSurface()
  }

  private func updateReadingSurface() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let opacity = glassStyle.map {
        AppMaterialPolicy.readingSurfaceOpacity(style: $0, isDark: isDark)
      } ?? 0
      readingSurface.layer?.backgroundColor =
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
    }
  }

  override func updateTrackingAreas() {
    if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    pointerTrackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    onPointerChange?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onPointerChange?(false)
  }
}
