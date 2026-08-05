import Combine
import Darwin
import Foundation

@MainActor
final class SystemMetricsStore: ObservableObject {
  @Published private(set) var snapshot = SystemSnapshot.empty
  private(set) var history: [SystemHistoryPoint] = []

  func update(from source: SystemSnapshot) {
    var metrics = source
    metrics.processes = []
    let cutoff = metrics.timestamp.addingTimeInterval(-60)
    history.removeAll { $0.timestamp < cutoff }
    history.append(
      SystemHistoryPoint(
        timestamp: metrics.timestamp,
        cpuPercent: metrics.cpu.total,
        memoryPercent: metrics.memory.fraction * 100,
        diskReadRate: metrics.disk.readRate,
        diskWriteRate: metrics.disk.writeRate,
        networkDownloadRate: metrics.network.downloadRate,
        networkUploadRate: metrics.network.uploadRate,
        temperatureCelsius: metrics.cpu.temperature.socCelsius,
        systemPowerWatts: metrics.power.systemWatts,
        chargingPowerWatts: metrics.power.chargingWatts,
        fanReadings: metrics.cooling.fans.map {
          FanHistoryReading(id: $0.id, rpm: $0.currentRPM)
        }
      )
    )
    snapshot = metrics
  }
}

enum ProcessSamplingClient: Hashable, Sendable {
  case processManagement
  case menuBar
}

enum MetricsSamplingClient: Hashable, Sendable {
  case mainWindow
  case menuBar
}

@MainActor
final class SystemMonitor: ObservableObject {
  @Published private(set) var processes: [ProcessRow] = []
  let metrics = SystemMetricsStore()
  private(set) var processHistory: [ProcessHistoryPoint] = []
  @Published private(set) var isRefreshing = false
  @Published var isPaused = false

  private(set) var refreshInterval: Double = 2

  private let metricsSampler = SystemSampler()
  private let processSampler = SystemSampler()
  private var metricsMonitoringTask: Task<Void, Never>?
  private var processMonitoringTask: Task<Void, Never>?
  private var trackedPID: Int32?
  private var metricsSamplingClients: Set<MetricsSamplingClient> = []
  private var processSamplingClients: Set<ProcessSamplingClient> = []
  private var processResumeTask: Task<Void, Never>?
  private var manualRefreshTask: Task<Void, Never>?
  private var processSamplingGeneration = 0
  private var metricsRefreshing = false
  private var processesRefreshing = false

  func start() {
    guard metricsMonitoringTask == nil else { return }
    startMetricsMonitoring()
  }

  func updateRefreshInterval(_ interval: Double) {
    let normalizedInterval = [0.5, 1, 2, 5].contains(interval) ? interval : 2
    guard refreshInterval != normalizedInterval else { return }

    refreshInterval = normalizedInterval

    let wasMonitoringMetrics = metricsMonitoringTask != nil
    let wasMonitoringProcesses = processMonitoringTask != nil
    metricsMonitoringTask?.cancel()
    metricsMonitoringTask = nil
    processMonitoringTask?.cancel()
    processMonitoringTask = nil

    if wasMonitoringMetrics {
      startMetricsMonitoring()
    }
    if wasMonitoringProcesses {
      startProcessMonitoring(generation: processSamplingGeneration)
    }
  }

  private func startMetricsMonitoring() {
    metricsMonitoringTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let refreshStartedAt = ProcessInfo.processInfo.systemUptime
        if !isPaused {
          await refreshMetrics()
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - refreshStartedAt
        let activeInterval = self.metricsSamplingClients.isEmpty
          ? max(2, self.refreshInterval)
          : self.refreshInterval
        let delaySeconds = max(0.05, max(0.2, activeInterval) - elapsed)
        let delay = UInt64(delaySeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  func stop() {
    metricsMonitoringTask?.cancel()
    metricsMonitoringTask = nil
    processMonitoringTask?.cancel()
    processMonitoringTask = nil
    processResumeTask?.cancel()
    processResumeTask = nil
    manualRefreshTask?.cancel()
    manualRefreshTask = nil
    isRefreshing = false
  }

  func refreshMetrics() async {
    guard !metricsRefreshing else { return }
    metricsRefreshing = true
    let nextSnapshot = await metricsSampler.sampleMetrics()
    metrics.update(from: nextSnapshot)
    metricsRefreshing = false
  }

  func refreshProcesses(generation: Int? = nil) async {
    guard isProcessSamplingRequested, !processesRefreshing else { return }
    processesRefreshing = true
    let samplingGeneration = generation ?? processSamplingGeneration
    let nextProcesses = await processSampler.sampleProcesses()
    if isProcessSamplingRequested, samplingGeneration == processSamplingGeneration {
      var processSnapshot = metrics.snapshot
      processSnapshot.processes = nextProcesses
      recordHistory(for: processSnapshot)
      processes = nextProcesses
    }
    processesRefreshing = false
  }

  func refreshNow(forceProcessSample: Bool = true) {
    guard manualRefreshTask == nil else { return }
    let shouldRefreshProcesses = forceProcessSample && isProcessSamplingRequested
    let generation = processSamplingGeneration
    isRefreshing = true
    manualRefreshTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isRefreshing = false
        self.manualRefreshTask = nil
      }
      await self.refreshMetrics()
      if shouldRefreshProcesses {
        await self.refreshProcesses(generation: generation)
      }
    }
  }

  func setProcessSampling(_ isEnabled: Bool, for client: ProcessSamplingClient) {
    let wasRequested = isProcessSamplingRequested
    if isEnabled {
      processSamplingClients.insert(client)
    } else {
      processSamplingClients.remove(client)
    }
    let isRequested = isProcessSamplingRequested
    guard wasRequested != isRequested else { return }

    processSamplingGeneration += 1
    processResumeTask?.cancel()
    processResumeTask = nil
    processMonitoringTask?.cancel()
    processMonitoringTask = nil

    guard isRequested else { return }

    let generation = processSamplingGeneration
    processResumeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard let self, !Task.isCancelled,
        self.isProcessSamplingRequested,
        self.processSamplingGeneration == generation
      else {
        return
      }
      self.startProcessMonitoring(generation: generation)
    }
  }

  func setMetricsSampling(_ isActive: Bool, for client: MetricsSamplingClient) {
    let wasActive = !metricsSamplingClients.isEmpty
    if isActive {
      metricsSamplingClients.insert(client)
    } else {
      metricsSamplingClients.remove(client)
    }
    let isPresentationActive = !metricsSamplingClients.isEmpty
    guard wasActive != isPresentationActive, metricsMonitoringTask != nil else {
      return
    }

    metricsMonitoringTask?.cancel()
    metricsMonitoringTask = nil
    startMetricsMonitoring()
  }

  private func startProcessMonitoring(generation: Int) {
    processMonitoringTask?.cancel()
    processMonitoringTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled,
        self.isProcessSamplingRequested,
        self.processSamplingGeneration == generation
      {
        let refreshStartedAt = ProcessInfo.processInfo.systemUptime
        if !self.isPaused {
          await self.refreshProcesses(generation: generation)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - refreshStartedAt
        // Enumerating every process includes ps, nettop, and per-PID kernel queries.
        // Keep that heavier path independent from the lightweight metric cadence.
        let delaySeconds = max(0.05, max(2, self.refreshInterval) - elapsed)
        let delay = UInt64(delaySeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private var isProcessSamplingRequested: Bool {
    !processSamplingClients.isEmpty
  }

  func togglePause() {
    isPaused.toggle()
    if !isPaused {
      refreshNow()
    }
  }

  func send(signal: Int32, to process: ProcessRow) -> String? {
    guard process.pid > 1, process.pid != ProcessInfo.processInfo.processIdentifier else {
      return "This process is protected."
    }
    if Darwin.kill(process.pid, signal) == 0 {
      refreshNow()
      return nil
    }
    return String(cString: strerror(errno))
  }

  func history(for pid: Int32) -> [ProcessHistoryPoint] {
    trackedPID == pid ? processHistory : []
  }

  func trackProcess(_ pid: Int32?) {
    guard trackedPID != pid else { return }
    trackedPID = pid
    processHistory = []
  }

  private func recordHistory(for nextSnapshot: SystemSnapshot) {
    guard let trackedPID else {
      if !processHistory.isEmpty {
        processHistory = []
      }
      return
    }
    let cutoff = nextSnapshot.timestamp.addingTimeInterval(-60)
    guard let process = nextSnapshot.processes.first(where: { $0.pid == trackedPID }) else {
      processHistory = []
      return
    }
    processHistory.removeAll { $0.timestamp < cutoff }
    processHistory.append(
      ProcessHistoryPoint(
        timestamp: nextSnapshot.timestamp,
        cpuPercent: process.cpuPercent,
        memoryBytes: process.memoryBytes,
        diskRate: process.diskReadRate + process.diskWriteRate,
        networkRate: process.networkDownloadRate + process.networkUploadRate
      ))
  }
}
