import Foundation
import CoreMedia

public struct KeyframeIndex: Equatable {
    /// Sorted ascending presentation timestamps of sync samples in the video track.
    public let times: [CMTime]

    public init(times: [CMTime]) {
        self.times = times
    }

    public var isEmpty: Bool { times.isEmpty }
    public var count: Int { times.count }
    public var first: CMTime? { times.first }
    public var last: CMTime? { times.last }

    /// Nearest keyframe time to `t`. Returns nil iff `times` is empty.
    public func nearest(to t: CMTime) -> CMTime? {
        guard !times.isEmpty else { return nil }
        let i = lowerBound(t)
        if i == 0 { return times[0] }
        if i == times.count { return times.last }
        let prev = times[i - 1]
        let next = times[i]
        let dPrev = abs(CMTimeSubtract(t, prev).seconds)
        let dNext = abs(CMTimeSubtract(next, t).seconds)
        return dPrev <= dNext ? prev : next
    }

    /// Largest keyframe time ≤ `t`. Returns nil if no such keyframe exists.
    public func floor(_ t: CMTime) -> CMTime? {
        guard !times.isEmpty else { return nil }
        let i = upperBound(t)
        return i == 0 ? nil : times[i - 1]
    }

    /// Smallest keyframe time ≥ `t`. Returns nil if no such keyframe exists.
    public func ceil(_ t: CMTime) -> CMTime? {
        guard !times.isEmpty else { return nil }
        let i = lowerBound(t)
        return i == times.count ? nil : times[i]
    }

    /// First index `i` such that `times[i] >= t`.
    private func lowerBound(_ t: CMTime) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(times[mid], t) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// First index `i` such that `times[i] > t`.
    private func upperBound(_ t: CMTime) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if CMTimeCompare(times[mid], t) <= 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
