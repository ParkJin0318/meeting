import Testing
import Foundation
@testable import MeetingCore

struct TranscriptRepeatsTests {
    private func line(_ text: String, _ start: TimeInterval,
                      speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: start + 5, text: text)
    }

    @Test func foldsConsecutiveRepeatsOfSameSpeaker() {
        let result = TranscriptRepeats.fold([
            line("다음 시간에는 정렬을 봅니다.", 0),
            line("시청해 주셔서 감사합니다.", 5),
            line("시청해 주셔서 감사합니다. ", 10),
            line("시청해 주셔서 감사합니다.", 15),
        ])
        #expect(result.folded == 2)
        #expect(result.kept.map(\.start) == [0, 5])
    }

    @Test func keepsRepeatAcrossSpeakers() {
        let result = TranscriptRepeats.fold([
            line("네, 맞아요.", 0, speaker: TranscriptSegment.Label.me),
            line("네, 맞아요.", 5, speaker: TranscriptSegment.Label.other(1)),
        ])
        #expect(result.folded == 0)
        #expect(result.kept.count == 2)
    }

    @Test func keepsRepeatSeparatedByOtherLine() {
        let result = TranscriptRepeats.fold([
            line("질문 있나요?", 0), line("없습니다.", 5), line("질문 있나요?", 10),
        ])
        #expect(result.folded == 0)
    }

    @Test func emptyInputFoldsNothing() {
        let result = TranscriptRepeats.fold([])
        #expect(result.kept.isEmpty)
        #expect(result.folded == 0)
        #expect(TranscriptRepeats.note(folded: 0) == nil)
    }
}
