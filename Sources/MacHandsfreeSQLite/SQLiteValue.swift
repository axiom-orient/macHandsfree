package import Foundation

package enum SQLiteValue: Sendable, Equatable {
  case null
  case integer(Int64)
  case number(Double)
  case text(String)
  case blob(Data)

  package var text: String? { if case .text(let value) = self { value } else { nil } }
  package var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
  package var number: Double? {
    switch self {
    case .number(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }
}
