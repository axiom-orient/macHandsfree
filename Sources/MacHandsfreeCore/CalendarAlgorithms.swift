package import Foundation

package struct TimeIntervalValue: Sendable, Equatable {
  package let start: Date
  package let end: Date
  package init(start: Date, end: Date) {
    self.start = start
    self.end = end
  }
}

package enum CalendarAlgorithms {
  package static func freeIntervals(
    range: TimeIntervalValue,
    busy: [TimeIntervalValue],
    minimumDuration: TimeInterval,
    limit: Int
  ) -> (values: [TimeIntervalValue], truncated: Bool) {
    guard range.start < range.end, minimumDuration > 0, limit > 0 else { return ([], false) }
    let clipped = busy.compactMap { interval -> TimeIntervalValue? in
      let start = max(interval.start, range.start)
      let end = min(interval.end, range.end)
      return start < end ? TimeIntervalValue(start: start, end: end) : nil
    }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    var merged: [TimeIntervalValue] = []
    for interval in clipped {
      if let last = merged.last, interval.start <= last.end {
        merged[merged.count - 1] = TimeIntervalValue(
          start: last.start, end: max(last.end, interval.end))
      } else {
        merged.append(interval)
      }
    }
    var free: [TimeIntervalValue] = []
    var cursor = range.start
    for interval in merged {
      if interval.start.timeIntervalSince(cursor) >= minimumDuration {
        free.append(TimeIntervalValue(start: cursor, end: interval.start))
      }
      cursor = max(cursor, interval.end)
    }
    if range.end.timeIntervalSince(cursor) >= minimumDuration {
      free.append(TimeIntervalValue(start: cursor, end: range.end))
    }
    return (Array(free.prefix(limit)), free.count > limit)
  }
}
