import Testing
import Foundation
@testable import MeetingCore

@Suite struct RecordingPauseTests {
    private let start = Date(timeIntervalSince1970: 1_786_000_000)

    @Test func accumulatesAcrossTwoPauses() {
        var pause = RecordingPause()
        pause.pause(at: start.addingTimeInterval(60))
        pause.resume(at: start.addingTimeInterval(90))
        pause.pause(at: start.addingTimeInterval(200))
        pause.resume(at: start.addingTimeInterval(260))

        #expect(pause.isPaused == false)
        #expect(pause.accumulated == 90)
        #expect(pause.total(at: start.addingTimeInterval(1_000)) == 90)
        #expect(pause.elapsed(from: start, at: start.addingTimeInterval(1_000)) == 910)
    }

    @Test func openPauseCountsUpToNow() {
        var pause = RecordingPause()
        pause.pause(at: start.addingTimeInterval(100))

        #expect(pause.isPaused)
        #expect(pause.total(at: start.addingTimeInterval(130)) == 30)
        #expect(pause.elapsed(from: start, at: start.addingTimeInterval(130)) == 100,
                "멈춘 동안 경과 시간이 얼어붙는다")
        #expect(pause.elapsed(from: start, at: start.addingTimeInterval(500)) == 100)
    }

    @Test func duplicatePauseAndResumeAreNoOps() {
        var pause = RecordingPause()
        pause.resume(at: start)
        #expect(pause == RecordingPause(), "멈춘 적 없는데 재개해도 장부는 비어 있다")

        pause.pause(at: start.addingTimeInterval(10))
        pause.pause(at: start.addingTimeInterval(20))
        pause.resume(at: start.addingTimeInterval(30))
        #expect(pause.accumulated == 20, "두 번째 pause는 첫 시각을 덮어쓰지 않는다")
    }

    @Test func clampsNegativeIntervals() {
        var pause = RecordingPause()
        pause.pause(at: start.addingTimeInterval(50))
        pause.resume(at: start.addingTimeInterval(40))
        #expect(pause.accumulated == 0)
        #expect(pause.elapsed(from: start.addingTimeInterval(100), at: start) == 0)
    }
}
