import Foundation
import MacHandsfreeCore

actor FileService: CurrentStateValidatedCommandService {
  let name = "files"
  private let reader: FileReadOperations
  private let planner: FileMutationPlanner
  private let mutations: FileMutationExecutor
  private let processRunner: any ProcessRunning

  init(processRunner: any ProcessRunning) {
    let fileManager = FileManager.default
    let inspection = FileSystemInspector(fileManager: fileManager)
    let planner = FileMutationPlanner(fileManager: fileManager, inspection: inspection)
    self.reader = FileReadOperations(fileManager: fileManager)
    self.planner = planner
    self.processRunner = processRunner
    self.mutations = FileMutationExecutor(
      fileManager: fileManager,
      inspection: inspection,
      planner: planner
    )
  }

  func preview(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    try planner.preview(command: command, input: input)
  }

  func execute(command: CommandSpec, input: JSONValue) async throws -> JSONValue {
    let object = try input.requiredObject()
    switch command.id {
    case "files.list": return try reader.list(object)
    case "files.stat": return try reader.metadata(object)
    case "files.search": return try FileSearch.search(object)
    case "files.read":
      switch try reader.read(object) {
      case .response(let response):
        return response
      case .textDocument(let data, let path, let format):
        let extraction = try await TextDocumentTextExtractor.extract(
          data,
          path: path,
          format: format,
          processRunner: processRunner
        )
        return .object([
          "path": .string(path), "encoding": .string("utf8"),
          "bytes": .integer(Int64(data.count)), "content": .string(extraction.text),
          "content_type": .string(extraction.contentType), "document": extraction.json,
        ])
      }
    case "files.patch", "files.write", "files.mkdir", "files.copy", "files.move", "files.delete":
      return try mutations.execute(command: command, input: input)
    default:
      throw AgentError(
        code: "unsupported_file_command",
        message: "File service does not support the command",
        exitCode: 5
      )
    }
  }

  func executeMutation(
    command: CommandSpec,
    input: JSONValue,
    plannedPreview: JSONValue
  ) async throws -> JSONValue {
    try mutations.executePlanned(
      command: command,
      input: input,
      plannedPreview: plannedPreview
    )
  }
}
