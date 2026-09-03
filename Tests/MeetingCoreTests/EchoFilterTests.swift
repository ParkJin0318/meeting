import Testing
import Foundation
@testable import MeetingCore

struct EchoFilterTests {
    private func mine(_ text: String, _ start: TimeInterval,
                      _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: TranscriptSegment.Label.me,
                          start: start, end: end, text: text)
    }

    private func theirs(_ text: String, _ start: TimeInterval,
                        _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: TranscriptSegment.Label.other(1),
                          start: start, end: end, text: text)
    }

    @Test func foldsEchoDespiteDifferingWords() {
        let system = [theirs("저는 검색 팀에서 색인 파이프라인을 맡고 있습니다. 잘 부탁드리겠습니다. "
                             + "아마 공지에서 글로는 많이 보셨죠?", 0, 18)]
        let mic = [mine("저는 검색 팀에서 색인 파이브라인을 맡고 있습니다. 잘 부탁드리겠습니다. "
                        + "아마 공지에서 글로는 많이 보셨죠?", 0, 18)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 1)
        #expect(result.kept.isEmpty)
    }

    @Test func foldsLaggingEchoWithShiftedBoundaries() {
        let system = [theirs("제가 어제 로그를 보면서 발견한 케이스가 있어가지고 캐시 만료 처리 관련해서 "
                             + "만약에 작업을 하게 된다면 범위가 어느 정도 될지는 오늘 확인 예정이고 또 배치 "
                             + "서버랑 웹 작업은 금요일부터 착수할 예정입니다. 이상입니다.", 343, 359)]
        let mic = [mine("서버랑 웹 작업은 금요일부터 착수할 예정입니다. 감사합니다.", 359, 366)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 1, "16초 밀린 에코를 놓쳤다")
    }

    @Test func keepsSegmentThatMixesMyWordsWithEcho() {
        let system = [theirs("요즘에 데이터 팀은 바쁜 것 같긴 하고 플랫폼 쪽은 일이 어느 정도 있으세요? "
                             + "혼자서 가능하시잖아요.", 992, 1004)]
        let mic = [mine("일은 많아요. 혼자서 가능하시잖아요.", 1004, 1010)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 0, "내 말이 섞인 줄을 접었다 — '일은 많아요'가 사라진다")
        #expect(result.kept.count == 1)
    }

    @Test func keepsMyOwnSpeech() {
        let system = [theirs("네 지금 디자인 검수 진행 중이시라 이슈도 올라오고 있고 계속 추가 논의가 있어서 "
                             + "변경 사항도 있고 한 상태인데요.", 180, 200)]
        let mic = [mine("아 제가 위키무서로 옮겨서 그 쓰레드의 위키무서를 올렸는데 다시 불러볼게요. 네 알겠습니다.",
                        185, 198)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 0)
        #expect(result.kept.count == 1)
    }

    @Test func keepsShortBackchannel() {
        let system = [theirs("네 알겠습니다", 10, 12)]
        let mic = [mine("네 알겠습니다", 10, 12)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 0, "맞장구를 에코로 접었다")
    }

    @Test func keepsSameWordsSpokenMuchLater() {
        let system = [theirs("처음엔 200ms 만에 응답이 됐었는데 나중에 한 1년 뒤에 보니까 API 기능들이 "
                             + "붙고 붙고 붙어서 4초 걸린다든지 이런 일들이 실제로 일어나거든요.", 60, 80)]
        let mic = [mine("처음엔 200ms 만에 응답이 됐었는데 나중에 한 1년 뒤에 보니까 API 기능들이 "
                        + "붙고 붙고 붙어서 4초 걸린다든지 이런 일들이 실제로 일어나거든요.", 900, 920)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 0, "15분 떨어진 발화를 에코로 접었다")
    }

    @Test func leavesEchoFreeMeetingUntouched() {
        let system = [theirs("이번 VoC는 알림 설정 관련 문의가 가장 많았습니다.", 0, 6),
                      theirs("웹에서는 비밀번호 재설정 플로우가 아예 없습니다.", 20, 26)]
        let mic = [mine("그 건은 제가 서버 쪽이랑 오후에 미팅 잡아서 공수 확인해 보겠습니다.", 6, 14),
                   mine("iOS도 동일하게 필요한 작업인지 확인해서 공유드릴게요.", 26, 33)]
        let result = EchoFilter.fold(mic: mic, against: system)
        #expect(result.folded == 0)
        #expect(result.kept.count == 2)
    }

    @Test func keepsEverythingWhenThereIsNoOtherTrack() {
        let mic = [mine("오늘 스프린트 회고 시작하겠습니다. 먼저 지난주 액션 아이템부터 보겠습니다.", 0, 8)]
        let result = EchoFilter.fold(mic: mic, against: [])
        #expect(result.folded == 0)
        #expect(result.kept.count == 1)
    }

    @Test func noteReportsFoldedCountOnlyWhenSomethingWasFolded() {
        #expect(EchoFilter.note(folded: 0) == nil)
        #expect(EchoFilter.note(folded: 107)?.contains("107줄") == true)
    }
}
