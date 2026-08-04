import SwiftUI

struct MemoryToolView: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var store: MaintenanceStore

  private var memory: MemoryUsage { metrics.snapshot.memory }

  var body: some View {
    VStack(spacing: 0) {
      SystemToolPageHeader(destination: .memory)

      if store.activity?.tool == .memory {
        MaintenanceActivityInlineView(tool: .memory)
        Divider()
      }

      ScrollView {
        VStack(spacing: 28) {
          memoryGauge
          memoryBreakdown
          Divider()
            .frame(maxWidth: 620)
          VStack(spacing: 8) {
            Text("Release Inactive File Cache")
              .font(.headline)
            Text("macOS decides which cached data is eligible to release. Running applications are not closed.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 480)
          }

        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
      }
      .compactNativeScrollers()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: { store.releaseMemory() }) {
          Label("Release Memory", systemImage: "memorychip")
        }
        .help("Release Memory")
        .disabled(store.isBusy)
      }
    }
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

  private var memoryBreakdown: some View {
    HStack(spacing: 0) {
      memoryValue("Used", value: memory.used)
      Divider()
        .frame(height: 48)
      memoryValue("Available", value: memory.available)
      Divider()
        .frame(height: 48)
      memoryValue("Installed", value: memory.total)
    }
    .frame(maxWidth: 620)
    .padding(.vertical, 14)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func memoryValue(_ title: LocalizedStringKey, value: UInt64) -> some View {
    VStack(spacing: 4) {
      Text(DisplayFormat.bytes(value))
        .font(.title3.weight(.semibold))
        .monospacedDigit()
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}
