/// Command schema and execution share these limits. They are product policy, not user grants.
package enum WorkspaceToolPolicy {
  package enum Search {
    package static let defaultScanLimit = 2_000
    package static let maximumScanLimit = 10_000
    package static let defaultResultLimit = 50
    package static let maximumResultLimit = 200
    package static let maximumFileBytes = 256 * 1_024
    package static let maximumTotalBytes = 8 * 1_024 * 1_024
    package static let excerptCharacters = 240
    package static let maximumSkippedDetails = 64
    package static let excludedDirectories: Set<String> = [".git", ".build", "node_modules"]
  }
  package enum Patch {
    package static let maximumFileBytes = 1_024 * 1_024
    package static let maximumPreviewBytes = 64 * 1_024
    package static let maximumEditCharacters = 65_536
    package static let maximumEdits = 20
  }
  package enum Process {
    package static let timeout = 120
    package static let maximumTimeout = 600
    package static let defaultOutputBytes = 64 * 1_024
    package static let maximumOutputBytes = 1_024 * 1_024
    package static let maximumArguments = 128
    package static let maximumArgumentCharacters = 32_768
  }
}
