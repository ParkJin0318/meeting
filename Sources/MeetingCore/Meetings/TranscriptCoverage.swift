import Foundation

public struct TranscriptCoverage: Codable, Sendable, Hashable {

    public struct Gap: Codable, Sendable, Hashable {
        public let start: TimeInterval
        public let end: TimeInterval

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { max(0, end - start) }

        public var label: String {
            "\(TranscriptCoverage.clock(start)) ~ \(TranscriptCoverage.clock(end))"
                + " · \(Int(duration.rounded()))초 동안 전사가 없습니다"
        }
    }

    public let duration: TimeInterval
    public let gaps: [Gap]
    public let recoveredSeconds: TimeInterval

    public init(duration: TimeInterval, gaps: [Gap], recoveredSeconds: TimeInterval = 0) {
        self.duration = duration
        self.gaps = gaps
        self.recoveredSeconds = recoveredSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        gaps = try container.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        recoveredSeconds = try container
            .decodeIfPresent(TimeInterval.self, forKey: .recoveredSeconds) ?? 0
    }

    public var missingSeconds: TimeInterval { gaps.reduce(0) { $0 + $1.duration } }

    public var missingRatio: Double {
        guard duration > 0 else { return 0 }
        return min(1, missingSeconds / duration)
    }

    public var hasLoss: Bool { !gaps.isEmpty }

    public var note: String? {
        var parts: [String] = []
        if hasLoss {
            let percent = Int((missingRatio * 100).rounded())
            parts.append("전사가 \(gaps.count)곳에서 \(Int(missingSeconds.rounded()))초를 비웠습니다"
                + " — 전체 \(Int(duration.rounded()))초의 \(percent)%입니다.")
        }
        if recoveredSeconds >= 1 {
            parts.append("빠졌던 \(Int(recoveredSeconds.rounded()))초는 재전사로 채웠습니다.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static let minimumGap: TimeInterval = 10

    public static func measure(segments: [TranscriptSegment], duration: TimeInterval,
                               minimumGap: TimeInterval = TranscriptCoverage.minimumGap,
                               recoveredSeconds: TimeInterval = 0)
    -> TranscriptCoverage? {
        guard duration > 0 else { return nil }
        var gaps: [Gap] = []
        var cursor: TimeInterval = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.start - cursor >= minimumGap {
                gaps.append(Gap(start: cursor, end: segment.start))
            }
            cursor = max(cursor, segment.end)
        }
        if duration - cursor >= minimumGap {
            gaps.append(Gap(start: cursor, end: duration))
        }
        return TranscriptCoverage(duration: duration, gaps: gaps,
                                  recoveredSeconds: recoveredSeconds)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
