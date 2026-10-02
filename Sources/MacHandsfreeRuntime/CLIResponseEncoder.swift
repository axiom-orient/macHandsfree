import Foundation
package import MacHandsfreeCore

/// Serializes observed CLI results without turning delivery failure into no-effect evidence.
package enum CLIResponseEncoder {
  package static func encode(
    _ response: ResponseEnvelope, invocation: ResolvedCommand?
  ) -> CLIResult {
    do {
      return CLIResult(
        output: try response.json.encoded() + Data([0x0A]),
        exitCode: response.error?.exitCode ?? 0
      )
    } catch {
      let outcomeUncertain = response.error?.outcomeUncertain == true
        || (response.ok && invocation?.mode == .execute && invocation?.spec.kind == .mutation)
      let failure = ResponseEnvelope.failure(
        command: response.json["command"]?.stringValue,
        error: AgentError(
          code: "encoding_failed",
          message: "Could not encode response",
          details: ["reason": .string(String(describing: error))],
          exitCode: 5, outcomeUncertain: outcomeUncertain
        )
      )
      if let output = try? failure.json.encoded() + Data([0x0A]) {
        return CLIResult(output: output, exitCode: 5)
      }
      return CLIResult(
        output: Self.emergencyEncodingFailure(outcomeUncertain: outcomeUncertain), exitCode: 5)
    }
  }
  private static func emergencyEncodingFailure(outcomeUncertain: Bool) -> Data {
    #if os(macOS)
      let platform = "macos"
    #else
      let platform = "linux"
    #endif
    let line =
      #"{"error":{"code":"encoding_failed","details":{},"message":"Could not encode response","outcome_uncertain":"#
      + String(outcomeUncertain) + #"},"meta":{"platform":""#
      + platform + #"","product":""# + ProductInfo.name
      + #"","replayed":false,"schema_version":"#
      + String(ProductInfo.responseSchemaVersion)
      + #","timestamp":"1970-01-01T00:00:00.000Z","version":""#
      + ProductInfo.version + #""},"ok":false}"#
    return Data(line.utf8) + Data([0x0A])
  }
}
