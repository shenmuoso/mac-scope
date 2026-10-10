import AppKit
import SwiftUI

struct SidebarItemIcon: View {
  let systemImage: String
  let color: Color

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(color.gradient)
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
      Image(systemName: systemImage)
        .symbolRenderingMode(.monochrome)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
    }
    .frame(width: 20, height: 20)
    .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
    .accessibilityHidden(true)
  }
}
