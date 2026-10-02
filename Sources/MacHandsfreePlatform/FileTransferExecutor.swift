import Foundation
import MacHandsfreeCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileTransferExecutor {
  private let fileManager: FileManager
  private let inspection: FileSystemInspector
  private let planner: FileMutationPlanner

  init(
    fileManager: FileManager,
    inspection: FileSystemInspector,
    planner: FileMutationPlanner
  ) {
    self.fileManager = fileManager
    self.inspection = inspection
    self.planner = planner
  }

  func copy(
    _ object: [String: JSONValue],
    plannedPreview: JSONValue? = nil,
    validateBeforeCommit: () throws -> Void = {}
  ) throws -> JSONValue {
    let transfer = try inspection.inspectTransfer(object)
    try inspection.requireCopyableTree(transfer.source)
    let createdParents = try PlannedDirectories.create(transfer.parents)
    let source = transfer.source
    let destination = transfer.destination
    let destinationInfo = transfer.destinationInfo
    let temporary = temporarySibling(of: destination)

    do {
      try fileManager.copyItem(at: source, to: temporary)
      try StagedTreeSynchronizer.sync(temporary)
      if let plannedPreview {
        try planner.validateStagedCopy(plannedPreview: plannedPreview, stagedURL: temporary)
      }
    } catch {
      try cleanupFailedCopy(
        temporary: temporary,
        createdParents: createdParents,
        originalError: error
      )
      if let agentError = error as? AgentError {
        throw agentError
      }
      throw AgentError(
        code: "file_copy_failed",
        message: "Could not stage a copy without modifying the destination",
        details: ["reason": .string(String(describing: error))],
        exitCode: 5
      )
    }

    var publicationCommitted = false
    do {
      if destinationInfo != nil {
        try AtomicPathTransaction.exchange(
          temporary,
          destination,
          validateBeforeCommit: validateBeforeCommit
        ) {
          if let plannedPreview {
            try planner.validateRelocatedGuard(
              plannedPreview: plannedPreview,
              role: "destination",
              currentURL: temporary
            )
            try planner.validateStagedCopy(
              plannedPreview: plannedPreview,
              stagedURL: destination
            )
          }
        }
        publicationCommitted = true
        try removeDisplacedRegularFile(temporary, publishedAt: destination)
      } else {
        try AtomicPathTransaction.detach(
          temporary,
          to: destination,
          validateBeforeCommit: validateBeforeCommit
        ) {
          if let plannedPreview {
            try planner.validateStagedCopy(
              plannedPreview: plannedPreview,
              stagedURL: destination
            )
          }
        }
        publicationCommitted = true
      }
    } catch let rollback as AtomicPathTransaction.RollbackFailure {
      throw rollback.error
    } catch {
      if publicationCommitted { throw error }
      let publicationError = copyPublicationError(error, replacingExisting: destinationInfo != nil)
      try cleanupFailedCopy(
        temporary: temporary,
        createdParents: createdParents,
        originalError: publicationError
      )
      throw publicationError
    }

    try DirectorySync.sync(destination.deletingLastPathComponent())
    try createdParents.syncParents()
    return .object([
      "source": .string(source.path),
      "destination": .string(destination.path),
      "replaced": .bool(destinationInfo != nil),
    ])
  }

  func move(
    _ object: [String: JSONValue],
    plannedPreview: JSONValue? = nil,
    validateBeforeCommit: () throws -> Void = {}
  ) throws -> JSONValue {
    let transfer = try inspection.inspectTransfer(object)
    let createdParents = try PlannedDirectories.create(transfer.parents)
    let source = transfer.source
    let destination = transfer.destination
    let destinationInfo = transfer.destinationInfo

    var displacedDestination: URL?
    do {
      if destinationInfo == nil {
        try AtomicPathTransaction.detach(
          source,
          to: destination,
          validateBeforeCommit: validateBeforeCommit
        ) {
          if let plannedPreview {
            try planner.validateRelocatedGuard(
              plannedPreview: plannedPreview,
              role: "source",
              currentURL: destination
            )
          }
        }
      } else {
        let displaced = temporarySibling(of: source)
        try AtomicPathTransaction.exchange(
          source,
          destination,
          validateBeforeCommit: validateBeforeCommit
        ) {
          if let plannedPreview {
            try planner.validateRelocatedGuard(
              plannedPreview: plannedPreview,
              role: "source",
              currentURL: destination
            )
            try planner.validateRelocatedGuard(
              plannedPreview: plannedPreview,
              role: "destination",
              currentURL: source
            )
          }
          try AtomicPathTransaction.detach(source, to: displaced) {
            if let plannedPreview {
              try planner.validateRelocatedGuard(
                plannedPreview: plannedPreview,
                role: "destination",
                currentURL: displaced
              )
            }
          }
        }
        displacedDestination = displaced
      }
    } catch let rollback as AtomicPathTransaction.RollbackFailure {
      throw rollback.error
    } catch {
      try createdParents.rollback(after: error)
      throw error
    }

    if let displacedDestination {
      try removeDisplacedRegularFile(displacedDestination, publishedAt: destination)
    }

    let sourceParent = source.deletingLastPathComponent()
    let destinationParent = destination.deletingLastPathComponent()
    try DirectorySync.sync(destinationParent)
    if sourceParent.path != destinationParent.path { try DirectorySync.sync(sourceParent) }
    try createdParents.syncParents()
    return .object([
      "source": .string(source.path),
      "destination": .string(destination.path),
      "replaced": .bool(destinationInfo != nil),
    ])
  }

  private func cleanupStagedItem(_ url: URL, after originalError: any Error) throws {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      if errno == ENOENT { return }
      throw stagingCleanupFailure(url: url, originalError: originalError, reason: nil)
    }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw stagingCleanupFailure(url: url, originalError: originalError, reason: error)
    }
  }

  private func removeDisplacedRegularFile(_ url: URL, publishedAt destination: URL) throws {
    var status: Int32
    repeat {
      status = unlink(url.path)
    } while status != 0 && errno == EINTR
    guard status == 0 else {
      throw AgentError(
        code: "file_replacement_cleanup_failed",
        message: "The replacement was published, but the displaced file could not be removed",
        details: [
          "destination": .string(destination.path),
          "displaced_path": .string(url.path),
          "errno": .integer(Int64(errno)),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }

  private func stagingCleanupFailure(
    url: URL,
    originalError: any Error,
    reason: (any Error)?
  ) -> AgentError {
    var details: [String: JSONValue] = [
      "staged_path": .string(url.path),
      "original_error": .string(String(describing: originalError)),
      "errno": .integer(Int64(errno)),
    ]
    if let reason { details["cleanup_error"] = .string(String(describing: reason)) }
    return AgentError(
      code: "file_staging_cleanup_failed",
      message: "A staged file item could not be removed after publication failed",
      details: details,
      exitCode: 5,
      outcomeUncertain: true
    )
  }

  private func cleanupFailedCopy(
    temporary: URL,
    createdParents: PlannedDirectories,
    originalError: any Error
  ) throws {
    var failures: [JSONValue] = []
    do {
      try cleanupStagedItem(temporary, after: originalError)
    } catch {
      failures.append(
        .object([
          "operation": .string("remove_staged_copy"),
          "path": .string(temporary.path),
          "reason": .string(String(describing: error)),
        ]))
    }
    do {
      try createdParents.rollback(after: originalError)
    } catch {
      failures.append(
        .object([
          "operation": .string("remove_created_parents"),
          "reason": .string(String(describing: error)),
        ]))
    }
    guard failures.isEmpty else {
      throw AgentError(
        code: "file_staging_cleanup_failed",
        message: "A failed copy could not clean up all preparatory filesystem effects",
        details: [
          "original_error": .string(String(describing: originalError)),
          "cleanup_failures": .array(failures),
        ],
        exitCode: 5,
        outcomeUncertain: true
      )
    }
  }

  private func copyPublicationError(
    _ error: any Error,
    replacingExisting: Bool
  ) -> any Error {
    guard let agentError = error as? AgentError else {
      return AgentError(
        code: replacingExisting ? "file_replace_failed" : "file_copy_failed",
        message: "Could not atomically publish the staged copy",
        details: ["reason": .string(String(describing: error))],
        exitCode: 5
      )
    }
    let mappedCode: String?
    if replacingExisting, agentError.code == "atomic_exchange_failed" {
      mappedCode = "file_replace_failed"
    } else if !replacingExisting, agentError.code == "atomic_rename_failed" {
      mappedCode = "file_copy_failed"
    } else {
      mappedCode = nil
    }
    guard let mappedCode else { return agentError }
    return AgentError(
      code: mappedCode,
      message: "Could not atomically publish the staged copy",
      details: agentError.details,
      exitCode: 5,
      outcomeUncertain: agentError.outcomeUncertain
    )
  }

  private func temporarySibling(of destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(
      ".mac-handsfree-\(UUID().uuidString).staged"
    )
  }

}
