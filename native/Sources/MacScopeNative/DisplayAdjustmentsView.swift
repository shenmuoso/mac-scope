import SwiftUI

struct DisplayAdjustmentsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var store: DisplayControlStore
  let display: DisplaySummary
  @State private var selectedProfile = DisplayColorProfiles.factoryID

  private var busy: Bool { store.busyDisplays.contains(display.id) || store.pendingChange != nil }
  private var colors: DisplayColorConfiguration? { store.colorConfigurations[display.id] }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 24) {
        hardwareSection.frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
        colorSection.frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 16) {
        hardwareSection
        Divider()
        colorSection
      }
    }
    .onChange(of: colors?.selectedID) { value in
      selectedProfile = value ?? DisplayColorProfiles.factoryID
    }
    .onAppear { selectedProfile = colors?.selectedID ?? DisplayColorProfiles.factoryID }
  }

  private var hardwareSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(display.isBuiltIn ? "Hardware Brightness" : "DDC Controls", systemImage: "sun.max")
          .font(.headline)
        Spacer()
        if store.busyDisplays.contains(display.id) {
          ProgressView().controlSize(.small)
        }
        Button { Task { await store.loadControls(display) } } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh Display Controls")
        .disabled(busy || store.isAdjusting(display))
      }
      if let hardware = store.hardware[display.id] {
        if hardware.brightness != nil {
          DisplayPercentControl(
            title: "Brightness", symbol: "sun.max", value: percentBinding(nil), busy: busy
          )
        }
        if !display.isBuiltIn {
          ForEach(DDCFeature.allCases) { feature in
            if hardware.ddc[feature] != nil {
              DisplayPercentControl(
                title: LocalizedStringKey(feature.title), symbol: feature.symbol,
                value: percentBinding(feature), busy: busy
              )
            } else if hardware.error == nil {
              HStack {
                Label(LocalizedStringKey(feature.title), systemImage: feature.symbol)
                Spacer()
                Text("Unavailable").foregroundStyle(.secondary)
              }
            }
          }
        }
        if let error = hardware.error {
          Text(AppLocalization.string(error, language: settings.language))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("Reading Display Controls").foregroundStyle(.secondary)
      }
    }
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Color Configuration", systemImage: "paintpalette").font(.headline)
      if let colors, colors.isAvailable {
        Text("Color Profile").font(.caption).foregroundStyle(.secondary)
        Picker("Color Profile", selection: $selectedProfile) {
          Text("\(AppLocalization.string("System Default", language: settings.language)) · \(colors.factoryName)")
            .tag(DisplayColorProfiles.factoryID)
          ForEach(colors.profiles) { profile in
            Text(profile.name).tag(profile.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(busy)
        HStack {
          Button("Restore Default Profile") {
            selectedProfile = DisplayColorProfiles.factoryID
            Task {
              await store.setProfile(DisplayColorProfiles.factoryID, display: display)
              selectedProfile = store.colorConfigurations[display.id]?.selectedID ?? DisplayColorProfiles.factoryID
            }
          }
          .disabled(busy || colors.selectedID == DisplayColorProfiles.factoryID)
          Spacer()
          Button("Apply Profile") {
            Task {
              await store.setProfile(selectedProfile, display: display)
              selectedProfile = store.colorConfigurations[display.id]?.selectedID ?? DisplayColorProfiles.factoryID
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(busy || selectedProfile == colors.selectedID)
        }
      } else if colors != nil {
        Text("ColorSync profiles are unavailable for this display.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func percentBinding(_ feature: DDCFeature?) -> Binding<Double> {
    Binding(
      get: { store.percent(for: feature, display: display) ?? 0 },
      set: { store.setBrightness($0, feature: feature, display: display) }
    )
  }
}

private struct DisplayPercentControl: View {
  let title: LocalizedStringKey
  let symbol: String
  @Binding var value: Double
  let busy: Bool

  var body: some View {
    VStack(spacing: 6) {
      HStack {
        Label(title, systemImage: symbol)
        Spacer()
        Text("\(Int(value.rounded()))%")
          .monospacedDigit()
          .frame(width: 48, alignment: .trailing)
      }
      Slider(value: $value, in: 0...100)
      .accessibilityLabel(title)
      .disabled(busy)
    }
  }
}
