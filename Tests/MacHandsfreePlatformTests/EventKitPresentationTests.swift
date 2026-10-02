import Foundation
import MacHandsfreeCore
import Testing

#if os(macOS)
  import EventKit
  @testable import MacHandsfreePlatform

  struct EventKitPresentationTests {
    @Test func capturedEnumValuesUseTheSameNamesAsNativePresentation() throws {
      let snapshot = JSONValue.object([
        "status": .integer(Int64(EKEventStatus.confirmed.rawValue)),
        "availability": .integer(Int64(EKEventAvailability.free.rawValue)),
      ])
      let result = try CalendarMutationSnapshot.presentation(snapshot)
      #expect(result["status"]?.stringValue == "confirmed")
      #expect(result["status"]?.stringValue == eventStatus(EKEventStatus.confirmed))
      #expect(result["availability"]?.stringValue == "free")
      #expect(result["availability"]?.stringValue == eventAvailability(EKEventAvailability.free))
      #expect(eventStatus(Int.max) == "unknown")
      #expect(eventAvailability(Int.max) == "unknown")
    }

    @Test func exactSnapshotNumbersKeepTheirStringRepresentationAndRejectNonfiniteValues() throws {
      #expect(try EventKitMutationSnapshot.number(1.25) == JSONValue.string("1.25"))
      do {
        _ = try EventKitMutationSnapshot.number(.infinity)
        Issue.record("A non-finite snapshot value must not be serialized")
      } catch let error as AgentError {
        #expect(error.code == "eventkit_snapshot_unavailable")
      }
    }
  }
#endif
