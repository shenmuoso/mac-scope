import SwiftUI

struct MemoryToolView: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var store: MaintenanceStore

  private var memory: MemoryUsage { metrics.snapshot.memory }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 24) {
          memoryGauge.frame(width: 160)
          VStack(spacing: 16) {
            memoryValue("Used", value: memory.used)
            memoryValue("Available", value: memory.available)
            memoryValue("Installed", value: memory.total)
          }
        }
      }
      Section {
        LabeledContent {
          Button(action: { store.releaseMemory() }) {
            Label("Release Memory", systemImage: "memorychip")
          }
          .disabled(store.isBusy)
        } label: {
          Text("Release Inactive File Cache")
        }
        Text("macOS decides which cached data is eligible to release. Running applications are not closed.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if store.activity?.tool == .memory {
        Section {
          MaintenanceActivityInlineView(tool: .memory)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: DetailLayout.readingWidth)
    .frame(maxWidth: .infinity)
    .compactNativeScrollers()
  }

  private var memoryGauge: some View {
    VStack(spacing: 10) {
      Gauge(value: min(1, max(0, memory.fraction))) {
        Text("Memory Used")
      } currentValueLabel: {
        Text(DisplayFormat.percent(memory.fraction * 100))
          .font(.title2.weight(.semibold))
          .monospacedDigit()
      }
      .gaugeStyle(.accessoryCircularCapacity)
      .tint(settings.activeTheme.memoryColor)
      .controlSize(.large)
      .scaleEffect(1.45)
      .frame(width: 150, height: 126)

      Text("Memory Used")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private func memoryValue(_ title: LocalizedStringKey, value: UInt64) -> some View {
    LabeledContent(title) {
      Text(DisplayFormat.bytes(value))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}
