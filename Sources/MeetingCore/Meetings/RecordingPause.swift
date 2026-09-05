import Foundation

/// 녹음 한 회차 안의 일시 중지 장부. 파일에는 멈춘 구간이 남지 않으므로(잘라 이어붙임)
/// 벽시계 경과에서 빼야 할 시간을 여기서만 센다.
public struct RecordingPause: Sendable, Equatable {
    public private(set) var accumulated: TimeInterval = 0
    public private(set) var since: Date?

    public init() {}

    public var isPaused: Bool { since != nil }

    public mutating func pause(at now: Date) {
        guard since == nil else { return }
        since = now
    }

    public mutating func resume(at now: Date) {
        guard let since else { return }
        accumulated += max(0, now.timeIntervalSince(since))
        self.since = nil
    }

    /// 지금까지 멈춘 총 시간. 진행 중인 구간도 `now`까지 센다.
    public func total(at now: Date) -> TimeInterval {
        accumulated + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// 실제로 녹음된 경과 시간.
    public func elapsed(from start: Date, at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(start) - total(at: now))
    }
}
