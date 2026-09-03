import Testing
import Foundation
@testable import MeetingCore

@Suite struct MeetingSummaryPromptTests {
    private func build(glossary: String = "", names: [String: String] = [:],
                       coverage: TranscriptCoverage? = nil,
                       language: String = "ko") -> String {
        MeetingSummaryPrompt.build(
            title: "서버 개발자 온보딩 세션 1주차",
            transcript: "[00:00] 상대1: 저는 검색 팀 색인 담당입니다",
            glossary: glossary, speakerNames: names, coverage: coverage,
            language: language)
    }

    @Test func asksForTheSummaryInTheMeetingLanguage() {
        #expect(build(language: "ko").contains("요약 본문은 한국어로 써라"))
        #expect(build(language: "en").contains("요약 본문은 English로 써라"))
        #expect(build(language: "ja").contains("요약 본문은 日本語로 써라"))
    }

    @Test func fallsBackToKoreanWhenLanguageIsBlank() {
        #expect(build(language: "  ").contains("요약 본문은 한국어로 써라"))
    }

    @Test func warnsAboutRemainingTranscriptGaps() {
        let prompt = build(coverage: TranscriptCoverage(
            duration: 3887, gaps: [.init(start: 2249, end: 2304)]))

        #expect(prompt.contains("전사가 끊긴 자리"))
        #expect(prompt.contains("앞뒤를 한 흐름으로 잇지 마라"))
        #expect(prompt.contains("1곳"))
        #expect(prompt.contains("55초"))
    }

    @Test func staysSilentWhenNothingIsMissing() {
        #expect(build(coverage: TranscriptCoverage(duration: 600, gaps: []))
            .contains("전사가 끊긴 자리") == false)
        #expect(build().contains("전사가 끊긴 자리") == false)
    }

    @Test func demandsChronologicalOrderInsideASection() {
        #expect(build().contains("전사 시각 오름차순"))
    }

    @Test func namesBothAutomaticLabelSchemes() {
        let prompt = build()
        #expect(prompt.contains("상대1"))
        #expect(prompt.contains("화자1"), "대면 경로 라벨을 프롬프트가 모르고 있었다")
    }

    @Test func offersConditionalSectionsWithAnOmitRule() {
        let prompt = build()
        for section in ["## 핵심 요약", "## 후속 조치", "## 핵심 메시지",
                        "## 주요 내용", "## 주요 용어", "## Q&A", "## 결정 사항"] {
            #expect(prompt.contains(section), "\(section) 안내가 빠졌다")
        }
        #expect(prompt.contains("해당 없으면 그 섹션째 빼라"))
        #expect(prompt.contains("실제로 정한 것이 있을 때만"),
                "결정 사항을 무조건 채우면 세미나 요약이 다시 망가진다")
    }

    @Test func demandsConcreteNumbersAndExamples() {
        let prompt = build()
        #expect(prompt.contains("원문 그대로"))
        #expect(prompt.contains("가입자 32만 명"), "구체가 무엇인지 예시로 못 박아야 한다")
        #expect(prompt.contains("뭉뚱그리면"))
    }

    @Test func keepsTimecodeContractAndExemptsGlossary() {
        let prompt = build()
        #expect(prompt.contains("[mm:ss]"))
        #expect(prompt.contains("지어내지 마라"))
        #expect(prompt.contains("`## 주요 용어`만 예외"))
    }

    @Test func carriesCorrectionDictionaryFromGlossaryAndNames() {
        let prompt = build(glossary: "맨인더미들, 옵저버빌리티", names: ["상대1": "임세아"])
        #expect(prompt.contains("# 표기 사전"))
        #expect(prompt.contains("임세아"))
        #expect(prompt.contains("맨인더미들"))
        #expect(prompt.contains("옵저버빌리티"))
    }

    @Test func sortsDictionaryAndDropsDuplicates() {
        let prompt = MeetingSummaryPrompt.build(
            title: "t", transcript: "x",
            glossary: "한도윤, 임세아, 한도윤", speakerNames: ["상대1": "임세아"])
        let line = prompt.components(separatedBy: "\n")
            .first { $0.contains("임세아") && $0.contains("한도윤") }
        #expect(line == "임세아, 한도윤", "사전이 정렬·중복 제거되지 않았다")
    }

    @Test func omitsDictionarySectionWhenThereIsNothingToCorrect() {
        #expect(!build().contains("# 표기 사전"))
    }

    @Test func carriesTitleTranscriptAndSubmitContract() {
        let prompt = build()
        #expect(prompt.contains("서버 개발자 온보딩 세션 1주차"))
        #expect(prompt.contains("저는 검색 팀 색인 담당입니다"))
        #expect(prompt.contains("`summary` 필드"), "구조화 출력 필드 지시가 빠졌다")
        #expect(prompt.contains("speakers"), "화자 제안 요청이 빠졌다")
    }

    @Test func summaryPreviewSurvivesNewSectionNames() {
        var meeting = Meeting(title: "세미나")
        meeting.summary = "## 핵심 요약\n\n- AI가 짠 서버 코드를 판단하는 능력이 목표 [05:48]"
        #expect(meeting.summaryPreview == "AI가 짠 서버 코드를 판단하는 능력이 목표 [05:48]")
    }
}

@Suite struct SpeakerSuggestionTests {
    private struct SuggestingAnalyzer: MeetingSummarizing {
        let speakers: [String: String]
        func summarize(prompt: String, title: String) async throws -> MeetingSummary {
            MeetingSummary(summary: "## 핵심 요약\n- 정리했습니다 [00:00]", speakers: speakers)
        }
    }

    private func center(_ store: SQLiteMeetingStore,
                        speakers: [String: String]) -> MeetingCenter {
        MeetingCenter(store: store, recorder: FakeRecorder(),
                      transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
                      analyzer: SuggestingAnalyzer(speakers: speakers),
                      mixer: PassthroughMixer())
    }

    @Test func summaryRunStoresSuggestionsWithoutApplyingThem() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: ["상대1": "임세아"])

        _ = try await center.startAdhocRecording(title: "온보딩")
        let done = try await center.stopRecording()

        #expect(done?.speakerNameSuggestions == ["상대1": "임세아"])
        #expect(done?.speakerNames.isEmpty == true, "제안이 사람 확인 없이 반영됐다")
    }

    @Test func doesNotSuggestForLabelsAlreadyNamed() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: ["상대1": "임세아", "상대2": "한도윤"])

        let meeting = try await center.startAdhocRecording(title: "온보딩")
        try await center.renameSpeaker(meetingID: meeting.id, label: "상대1", name: "세아님")
        let done = try await center.stopRecording()

        #expect(done?.speakerNameSuggestions == ["상대2": "한도윤"])
        #expect(done?.speakerNames["상대1"] == "세아님")
    }

    @Test func dropsSuggestionThatJustEchoesTheLabel() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: ["상대1": "상대1"])

        _ = try await center.startAdhocRecording(title: "온보딩")
        let done = try await center.stopRecording()

        #expect(done?.speakerNameSuggestions.isEmpty == true)
    }

    @Test func applyingSuggestionsRenamesAndClearsThemAtOnce() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: [:])
        let meeting = Meeting(
            title: "온보딩", status: .done,
            segments: [TranscriptSegment(speaker: "상대1", start: 0, end: 4,
                                         text: "저는 검색 팀 색인 담당입니다")],
            speakerNameSuggestions: ["상대1": "임세아"],
            transcript: "[00:00] 상대1: 저는 검색 팀 색인 담당입니다")
        try await store.upsert(.meeting, meeting)

        try await center.applySpeakerSuggestions(meetingID: meeting.id)

        let after = try #require(await store.fetch(.meeting, id: meeting.id, as: Meeting.self))
        #expect(after.speakerNames["상대1"] == "임세아")
        #expect(after.speakerNameSuggestions.isEmpty)
        #expect(after.transcript.contains("임세아"), "전사 문자열이 새 이름으로 다시 그려지지 않았다")
        #expect(!after.transcript.contains("상대1:"))
    }

    @Test func renamingClearsThatLabelsSuggestion() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: ["상대1": "임세아", "상대2": "한도윤"])

        _ = try await center.startAdhocRecording(title: "온보딩")
        let done = try #require(try await center.stopRecording())
        try await center.renameSpeaker(meetingID: done.id, label: "상대1", name: "다른이름")

        let after = try #require(await store.fetch(.meeting, id: done.id, as: Meeting.self))
        #expect(after.speakerNameSuggestions == ["상대2": "한도윤"])
    }

    @Test func dismissingClearsSuggestionsWithoutRenaming() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = center(store, speakers: ["상대1": "임세아"])

        _ = try await center.startAdhocRecording(title: "온보딩")
        let done = try #require(try await center.stopRecording())
        try await center.dismissSpeakerSuggestions(meetingID: done.id)

        let after = try #require(await store.fetch(.meeting, id: done.id, as: Meeting.self))
        #expect(after.speakerNameSuggestions.isEmpty)
        #expect(after.speakerNames.isEmpty)
    }

    @Test func legacyMeetingWithoutSuggestionKeyStillDecodes() throws {
        let json = """
        {"id":"m1","title":"옛 미팅","scheduledAt":768000000,"status":"done"}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.speakerNameSuggestions.isEmpty)
        #expect(meeting.title == "옛 미팅")
    }
}

@Suite struct EchoFoldingPipelineTests {
    private let mixed = URL(fileURLWithPath: "/tmp/m.mixed.m4a")
    private let system = URL(fileURLWithPath: "/tmp/m-system.mov")
    private let mic = URL(fileURLWithPath: "/tmp/m-mic.caf")

    @Test func foldsEchoedMicSegmentsAndKeepsTheReason() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TrackAwareTranscriber(byFile: [
                "m-system.mov": [TranscriptSegment(
                    start: 0, end: 18,
                    text: "저는 검색 팀에서 색인 파이프라인을 맡고 있습니다. 잘 부탁드리겠습니다.")],
                "m-mic.caf": [TranscriptSegment(
                    start: 0, end: 18,
                    text: "저는 검색 팀에서 색인 파이브라인을 맡고 있습니다. 잘 부탁드리겠습니다.")],
            ]),
            diarizer: nil, probe: FakeProbe(systemHasSpeech: true))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.count == 1, "같은 말이 두 벌로 남았다")
        #expect(result.segments.first?.speaker == "상대")
        #expect(result.diarizationNote?.contains("1줄을 중복으로 접었습니다") == true)
    }

    @Test func leavesGenuineMicSpeechAlone() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TrackAwareTranscriber(byFile: [
                "m-system.mov": [TranscriptSegment(
                    start: 0, end: 6, text: "이번 VoC는 알림 설정 문의가 가장 많았습니다")],
                "m-mic.caf": [TranscriptSegment(
                    start: 6, end: 14, text: "그 건은 제가 서버 쪽이랑 오후에 미팅 잡아서 확인해 보겠습니다")],
            ]),
            diarizer: nil, probe: FakeProbe(systemHasSpeech: true))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.count == 2)
        #expect(result.segments.map(\.speaker) == ["상대", "나"])
        #expect(result.diarizationNote?.contains("접었습니다") != true)
    }
}

@Suite struct SummaryRerunTests {
    private func meetingWithAudio(status: Meeting.Status,
                                  failureReason: String? = nil) throws -> (Meeting, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rerun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let micURL = dir.appendingPathComponent("mic.caf")
        let mixedURL = dir.appendingPathComponent("mixed.m4a")
        for url in [micURL, mixedURL] { try Data("녹음".utf8).write(to: url) }
        let meeting = Meeting(
            title: "서버 온보딩", status: status, micAudioPath: micURL.path,
            mixedAudioPath: mixedURL.path,
            segments: [TranscriptSegment(start: 0, end: 4, text: "이미 전사된 내용")],
            transcript: "[00:00] 이미 전사된 내용",
            summary: "## 핵심 내용\n- 옛 프롬프트가 만든 요약",
            failureReason: failureReason)
        return (meeting, dir)
    }

    @Test func completedMeetingCanRerunSummaryWithoutRetranscribing() async throws {
        final class CountingTranscriber: Transcribing, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.withLock { _calls } }
            func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
                lock.withLock { _calls += 1 }
                return [TranscriptSegment(start: 0, end: 3, text: "다시 전사됨")]
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let transcriber = CountingTranscriber()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: transcriber),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        let (meeting, dir) = try meetingWithAudio(status: .done)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsert(.meeting, meeting)

        #expect(meeting.canReprocess)
        #expect(meeting.reprocessesSummaryOnly)

        let prepared = try #require(try await center.prepareReprocess(meetingID: meeting.id))
        #expect(prepared.meeting.status == .summarizing, "완료 미팅을 전사 중으로 되돌렸다")
        let done = try await center.processRecording(prepared)

        #expect(transcriber.calls == 0, "전사가 다시 돌았다")
        #expect(done?.status == .done)
        #expect(done?.transcript.contains("이미 전사된 내용") == true)
    }

    @Test func secondRerunIsPreemptedByTheFirst() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        let (meeting, dir) = try meetingWithAudio(status: .done)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsert(.meeting, meeting)

        #expect(try await center.prepareReprocess(meetingID: meeting.id) != nil)
        #expect(try await center.prepareReprocess(meetingID: meeting.id) == nil)
    }

    @Test func transcriptionFailureStillRerunsTranscription() throws {
        let (meeting, dir) = try meetingWithAudio(status: .failed,
                                                  failureReason: "전사 실패: 모델이 죽었습니다.")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(meeting.canReprocess)
        #expect(!meeting.reprocessesSummaryOnly)
    }

    @Test func completedMeetingWithoutAudioCannotRerun() {
        var meeting = Meeting(title: "옛 미팅", status: .done)
        meeting.transcript = "[00:00] 내용"
        #expect(!meeting.canReprocess)
    }
}
