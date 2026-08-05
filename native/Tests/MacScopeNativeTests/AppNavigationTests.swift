import Foundation
import Testing

@testable import MacScopeNative

@Suite("App navigation")
struct AppNavigationTests {
  @Test("Process inspection opens process management")
  @MainActor
  func processInspectionDestination() throws {
    let suiteName = "AppNavigationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let navigation = AppNavigation(defaults: defaults)
    navigation.inspectProcess(42)

    #expect(navigation.destination == .processes)
    let request = try #require(navigation.processInspectionRequest)
    #expect(request.pid == 42)

    navigation.completeProcessInspection(request)
    #expect(navigation.processInspectionRequest == nil)
  }

  @Test("Startup items remain a restorable sidebar destination")
  @MainActor
  func startupItemsDestination() throws {
    let suiteName = "AppNavigationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let navigation = AppNavigation(defaults: defaults)
    navigation.destination = .startupItems

    #expect(AppNavigation(defaults: defaults).destination == .startupItems)
  }
}
