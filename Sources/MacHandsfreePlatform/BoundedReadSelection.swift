struct BoundedReadSelection<Element> {
  private let limit: Int
  private let capacity: Int
  private let precedes: (Element, Element) -> Bool
  private var candidates: [Element] = []
  var truncated: Bool { candidates.count > limit }

  init(limit: Int, by precedes: @escaping (Element, Element) -> Bool) {
    precondition(limit >= 0 && limit < Int.max)
    self.limit = limit
    capacity = limit + 1
    self.precedes = precedes
  }

  mutating func insert(_ candidate: Element) {
    if candidates.count < capacity {
      candidates.append(candidate)
      siftUp(from: candidates.count - 1)
    } else if precedes(candidate, candidates[0]) {
      candidates[0] = candidate
      siftDown(from: 0)
    }
  }

  // The max-heap root is the worst retained item; one extra slot records truncation.
  var page: [Element] {
    Array(candidates.sorted(by: precedes).prefix(limit))
  }

  private mutating func siftUp(from index: Int) {
    var child = index
    while child > 0 {
      let parent = (child - 1) / 2
      guard precedes(candidates[parent], candidates[child]) else { return }
      candidates.swapAt(parent, child)
      child = parent
    }
  }

  private mutating func siftDown(from index: Int) {
    var parent = index
    while true {
      let left = parent * 2 + 1
      guard left < candidates.count else { return }
      let right = left + 1
      var worst = left
      if right < candidates.count, precedes(candidates[left], candidates[right]) {
        worst = right
      }
      guard precedes(candidates[parent], candidates[worst]) else { return }
      candidates.swapAt(parent, worst)
      parent = worst
    }
  }
}
