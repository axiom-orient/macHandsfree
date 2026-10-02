package import Foundation
import MacHandsfreeCore

package struct StateDirectory: Sendable {
  package let url: URL

  package init(environment: [String: String]) throws {
    if let configured = environment["MAC_HANDSFREE_STATE_DIR"] {
      guard configured.hasPrefix("/"), !configured.contains("\0") else {
        throw AgentError.invalid("MAC_HANDSFREE_STATE_DIR must be an absolute path")
      }
      url = URL(fileURLWithPath: configured).standardizedFileURL
      return
    }

    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false)
    url = support.appending(path: "Mac Handsfree", directoryHint: .isDirectory)
  }
}
