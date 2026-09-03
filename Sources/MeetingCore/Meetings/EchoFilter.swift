import Foundation

public enum EchoFilter {
    public static let similarityThreshold = 0.8

    public static let minimumLength = 12

    public static let tolerance: TimeInterval = 5

    public struct Result: Sendable {
        public let kept: [TranscriptSegment]
        public let folded: Int

        public init(kept: [TranscriptSegment], folded: Int) {
            self.kept = kept
            self.folded = folded
        }
    }

    public static func fold(mic: [TranscriptSegment],
                            against other: [TranscriptSegment]) -> Result {
        guard !mic.isEmpty, !other.isEmpty else { return Result(kept: mic, folded: 0) }
        let others = other
            .map { (segment: $0, grams: bigrams(normalize($0.text))) }
            .sorted { $0.segment.start < $1.segment.start }

        var kept: [TranscriptSegment] = []
        var folded = 0
        for segment in mic {
            let text = normalize(segment.text)
            guard text.count >= minimumLength else {
                kept.append(segment)
                continue
            }
            var nearby: Set<Bigram> = []
            for entry in others {
                guard entry.segment.start - tolerance <= segment.end else { break }
                guard entry.segment.end + tolerance >= segment.start else { continue }
                nearby.formUnion(entry.grams)
            }
            if containment(of: bigrams(text), in: nearby) >= similarityThreshold {
                folded += 1
            } else {
                kept.append(segment)
            }
        }
        return Result(kept: kept, folded: folded)
    }

    public static func note(folded: Int) -> String? {
        guard folded > 0 else { return nil }
        return "마이크 트랙에서 스피커 소리가 함께 잡혀 \(folded)줄을 중복으로 접었습니다."
    }

    private struct Bigram: Hashable {
        let first: Character
        let second: Character
    }

    private static func normalize(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func bigrams(_ characters: [Character]) -> Set<Bigram> {
        guard characters.count > 1 else { return [] }
        var grams: Set<Bigram> = []
        for index in 0..<(characters.count - 1) {
            grams.insert(Bigram(first: characters[index], second: characters[index + 1]))
        }
        return grams
    }

    private static func containment(of mine: Set<Bigram>, in others: Set<Bigram>) -> Double {
        guard !mine.isEmpty else { return 0 }
        return Double(mine.intersection(others).count) / Double(mine.count)
    }
}
