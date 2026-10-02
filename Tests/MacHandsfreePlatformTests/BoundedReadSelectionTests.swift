import Testing
@testable import MacHandsfreePlatform

struct BoundedReadSelectionTests {
  @Test(arguments: [0, 1, 3, 8])
  func pageAndTruncationFollowTheSortedPrefixAfterEveryInsert(limit: Int) {
    let sequences = [
      [9, 1, 8, 2, 7, 3, 6, 4],
      [1, 2, 3, 4, 6, 7, 8, 9],
      [9, 8, 7, 6, 4, 3, 2, 1],
      [4, 4, 1, 4, 1, 2, 2, 4],
    ]
    for sequence in sequences {
      var selection = BoundedReadSelection<Int>(limit: limit, by: <)
      var observed: [Int] = []
      #expect(selection.page.isEmpty)
      #expect(!selection.truncated)
      for value in sequence {
        observed.append(value)
        selection.insert(value)
        #expect(selection.page == Array(observed.sorted().prefix(limit)))
        #expect(selection.truncated == (observed.count > limit))
      }
    }
  }
}
