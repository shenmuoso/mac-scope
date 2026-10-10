import Testing

@testable import MacScopeNative

@Suite("Fan control capability")
struct FanControlCapabilityTests {
  @Test("A complete and plausible fan range supports maximum cooling")
  func supportsVerifiedFanRange() {
    let cooling = CoolingUsage(
      state: .available,
      fans: [fan(maximumRPM: 6_000, targetRPM: 2_400)]
    )

    #expect(FanControlCapability.supports(cooling))
  }

  @Test("Fanless and unavailable Macs remain read-only")
  func rejectsUnavailableHardware() {
    #expect(
      !FanControlCapability.supports(CoolingUsage(state: .fanless, fans: []))
    )
    #expect(
      !FanControlCapability.supports(CoolingUsage(state: .unavailable, fans: []))
    )
  }

  @Test("Missing target or maximum RPM disables control")
  func rejectsIncompleteRange() {
    #expect(
      !FanControlCapability.supports(
        CoolingUsage(state: .available, fans: [fan(maximumRPM: nil, targetRPM: 2_000)])
      )
    )
    #expect(
      !FanControlCapability.supports(
        CoolingUsage(state: .available, fans: [fan(maximumRPM: 6_000, targetRPM: nil)])
      )
    )
  }

  @Test("Every detected fan must expose a plausible writable range")
  func rejectsPartialOrImplausibleRange() {
    let partial = CoolingUsage(
      state: .available,
      fans: [
        fan(id: 0, maximumRPM: 6_000, targetRPM: 2_000),
        fan(id: 1, maximumRPM: 45_000, targetRPM: 2_000),
      ]
    )

    #expect(!FanControlCapability.supports(partial))
    #expect(
      !FanControlCapability.supports(
        CoolingUsage(state: .available, fans: [fan(maximumRPM: 900, targetRPM: 800)])
      )
    )
    #expect(
      !FanControlCapability.supports(
        CoolingUsage(state: .available, fans: [fan(maximumRPM: 6_000, targetRPM: 7_000)])
      )
    )
  }

  private func fan(
    id: Int = 0,
    maximumRPM: Double?,
    targetRPM: Double?
  ) -> FanReading {
    FanReading(
      id: id,
      name: "Fan \(id + 1)",
      currentRPM: 2_000,
      minimumRPM: 1_200,
      maximumRPM: maximumRPM,
      targetRPM: targetRPM
    )
  }
}
