import SwiftUI

extension View {
  /// Fades the page when `id` changes. The fade is started by `withAnimation` at the
  /// selection change, so child controls keep their own layout.
  func pageTransition<ID: Hashable>(_ id: ID) -> some View {
    modifier(PageTransitionModifier(id: id))
  }
}

private struct PageTransitionModifier<ID: Hashable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var id: ID

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .id(id)
      .transition(reduceMotion ? .identity : .opacity)
  }
}
