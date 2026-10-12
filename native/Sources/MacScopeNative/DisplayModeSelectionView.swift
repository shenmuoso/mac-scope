import SwiftUI

struct DisplayModeSelectionView: View {
  @EnvironmentObject private var settings: AppSettings
  let display: DisplaySummary
  @Binding var filter: DisplayModeFilter
  @Binding var selection: String?
  @State private var page = 0
  private let pageSize = 6

  private var modes: [DisplayModeSummary] { display.modes.filter(filter.matches) }
  private var pageCount: Int { max(1, (modes.count + pageSize - 1) / pageSize) }
  private var currentPage: Int { min(page, pageCount - 1) }
  private var pageModes: [DisplayModeSummary] { Array(modes.dropFirst(currentPage * pageSize).prefix(pageSize)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Display Modes", systemImage: "list.bullet.rectangle").font(.headline)
        Spacer()
        Text(AppLocalization.string("%lld matching modes", language: settings.language, arguments: [Int64(modes.count)]))
          .font(.caption)
          .foregroundStyle(.secondary)
        if pageCount > 1 {
          pagination
        }
      }

      HStack(alignment: .bottom, spacing: 10) {
        filterPicker("Resolution", selection: $filter.resolution, values: resolutions)
        filterPicker("Scaling", selection: $filter.density, values: ["HiDPI", "Standard"])
        filterPicker(
          "Refresh Type", selection: $filter.refreshKind,
          values: DisplayRefreshKind.allCases.filter { kind in
            display.modes.contains { $0.refreshKind == kind }
          }.map(\.rawValue)
        )
        filterPicker("Refresh Rate", selection: $filter.frequency, values: frequencies)
        Button { filter = .current(display.currentMode) } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .help("Reset Mode Filters")
        .padding(.bottom, 1)
      }

      if modes.isEmpty {
        Text("No modes match these filters.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
      } else {
        modeList
      }
    }
    .onAppear(perform: revealSelection)
    .onChange(of: selection) { _ in revealSelection() }
    .onChange(of: modes.map(\.id)) { _ in revealSelection() }
  }

  private var pagination: some View {
    HStack(spacing: 6) {
      Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left") }
        .help("Previous Page")
        .disabled(currentPage == 0)
      Text("\(currentPage + 1) / \(pageCount)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 40)
      Button { page = min(pageCount - 1, currentPage + 1) } label: { Image(systemName: "chevron.right") }
        .help("Next Page")
        .disabled(currentPage == pageCount - 1)
    }
  }

  private var modeList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Picker("Matching Modes", selection: $selection) {
        ForEach(pageModes) { mode in
          modeRow(mode).tag(Optional(mode.id))
        }
      }
      .labelsHidden()
      .pickerStyle(.radioGroup)
      if modes.count > pageSize, pageModes.count < pageSize {
        Color.clear.frame(height: CGFloat(pageSize - pageModes.count) * 42)
      }
    }
    .onMoveCommand { direction in
      guard let index = modes.firstIndex(where: { $0.id == selection }) else {
        selection = modes.first?.id
        return
      }
      if direction == .down { selection = modes[min(index + 1, modes.count - 1)].id }
      if direction == .up { selection = modes[max(index - 1, 0)].id }
    }
    .accessibilityLabel("Matching Modes")
  }

  private func modeRow(_ mode: DisplayModeSummary) -> some View {
    HStack(spacing: 10) {
      Text(mode.resolutionLabel)
        .font(.body.weight(.medium))
        .monospacedDigit()
        .frame(width: 120, alignment: .leading)
      HStack(spacing: 6) {
        badge(mode.isHiDPI ? "HiDPI" : "1×")
          .help(mode.isHiDPI ? "HiDPI" : "Standard")
        badge(mode.aspectRatioLabel(isBuiltIn: display.isBuiltIn))
        if mode.refreshKind == .proMotion {
          badge("ProMotion", accent: true)
        } else {
          if mode.refreshKind == .variable { badge("VRR", accent: true) }
          badge(mode.frequencyLabel)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: "checkmark")
        .foregroundStyle(.tint)
        .opacity(mode.isCurrent ? 1 : 0)
        .frame(width: 16)
        .help(mode.isCurrent ? "Current" : "")
    }
    .frame(height: 42)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help("\(AppLocalization.string("Pixel Resolution", language: settings.language)): \(mode.pixelResolutionLabel)")
    .accessibilityValue(mode.isCurrent ? Text("Current") : Text(""))
  }

  private func badge(_ text: String, accent: Bool = false) -> some View {
    Text(text)
      .font(.caption)
      .monospacedDigit()
      .foregroundStyle(accent ? Color.accentColor : Color.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(accent ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
      .fixedSize()
  }

  private func filterPicker(_ title: LocalizedStringKey, selection: Binding<String>, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Picker(title, selection: selection) {
        Text("All").tag("")
        ForEach(values, id: \.self) { value in
          Text(value == "Standard" ? "1×" : AppLocalization.string(value, language: settings.language)).tag(value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func revealSelection() {
    if let index = modes.firstIndex(where: { $0.id == selection }) {
      page = index / pageSize
    } else {
      page = 0
    }
  }

  private var resolutions: [String] {
    display.modes.reduce(into: [String]()) { values, mode in
      if !values.contains(mode.resolutionLabel) { values.append(mode.resolutionLabel) }
    }
  }

  private var frequencies: [String] {
    display.modes.sorted { $0.refreshRate > $1.refreshRate }.reduce(into: [String]()) { values, mode in
      if !values.contains(mode.frequencyLabel) { values.append(mode.frequencyLabel) }
    }
  }
}
