import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import MeetingCore

final class FakeRecorder: MeetingRecording, @unchecked Sendable {
    private(set) var started: [String] = []
    private(set) var stopped = 0
    private(set) var pausedStates: [Bool] = []

    func start(meetingID: String) async throws {
        started.append(meetingID)
    }
    func stop() async throws -> RecordedAudio {
        stopped += 1
        return RecordedAudio(systemAudioURL: URL(fileURLWithPath: "/tmp/fake.mov"),
                             micURL: URL(fileURLWithPath: "/tmp/fake.caf"))
    }
    func setPaused(_ paused: Bool) {
        pausedStates.append(paused)
    }
}

struct FakeTranscriber: Transcribing {
    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(start: 0, end: 5, text: "위젯 개선 건 논의합시다"),
            TranscriptSegment(start: 5, end: 10, text: "다음 주까지 스펙 정리하겠습니다"),
        ]
    }
}

struct PassthroughMixer: AudioMixing {
    func mixForTranscription(system: URL?, mic: URL?,
                             micStartOffset: TimeInterval) async throws -> URL? {
        mic ?? system
    }
}

final class CenterBox: @unchecked Sendable {
    var center: MeetingCenter?
    var meetingID: String?
}

struct FakeAnalyzer: MeetingSummarizing {
    func summarize(prompt: String, title: String) async throws -> MeetingSummary {
        MeetingSummary(summary: "## 핵심 내용\n- 위젯 개선 논의")
    }
}

@Suite struct MeetingDocumentTests {
    private func sample() -> Meeting {
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        return Meeting(
            title: "위젯 킥오프", startedAt: start, endedAt: start.addingTimeInterval(3_900),
            status: .done,
            segments: [TranscriptSegment(speaker: "나", start: 0, end: 4, text: "시작하겠습니다"),
                       TranscriptSegment(speaker: "상대1", start: 4, end: 9, text: "네 좋습니다")],
            speakerNames: ["상대1": "김디자이너"],
            transcript: "옛 사본",
            summary: "## 핵심 내용\n- 위젯 범위 합의")
    }

    @Test func transcriptUsesCurrentSpeakerNames() {
        let text = MeetingDocument.transcriptText(sample())
        #expect(text.contains("김디자이너"))
        #expect(!text.contains("상대1"), "이름을 붙인 라벨이 그대로 나갔다")
        #expect(!text.contains("옛 사본"))
    }

    @Test func markdownCarriesHeaderSummaryAndTranscript() {
        let doc = MeetingDocument.markdown(sample())
        #expect(doc.hasPrefix("# 위젯 킥오프"))
        #expect(doc.contains("- 길이: 1시간 5분"))
        #expect(doc.contains("- 화자: 나, 김디자이너"))
        #expect(doc.contains("## 요약"))
        #expect(doc.contains("## 전사"))
    }

    @Test func durationExcludesPausedTime() {
        var meeting = sample()
        meeting.pausedSeconds = 600
        #expect(MeetingDocument.durationText(meeting) == "55분",
                "쉬는 시간은 파일에 없으므로 길이에서 뺀다")

        meeting.pausedSeconds = 10_000
        #expect(MeetingDocument.durationText(meeting) == "0분")
    }

    @Test func slugStripsPathUnsafeCharacters() {
        var meeting = sample()
        meeting.title = "QA/검수: 2차 (긴급)"
        let slug = MeetingDocument.slug(meeting)
        #expect(!slug.contains("/"))
        #expect(!slug.contains(":"))
        #expect(slug.hasPrefix(MeetingDocument.dateStamp(meeting.startedAt ?? Date())))
    }

    @Test func slugFallsBackToDateWhenTitleIsAllSymbols() {
        var meeting = sample()
        meeting.title = "///"
        #expect(MeetingDocument.slug(meeting) == MeetingDocument.dateStamp(meeting.startedAt!))
    }
}

@Suite struct MeetingListTests {
    private func meeting(_ title: String, at date: Date, summary: String = "",
                         transcript: String = "") -> Meeting {
        var meeting = Meeting(title: title, scheduledAt: date, summary: summary)
        meeting.transcript = transcript
        return meeting
    }

    @Test func groupsByRecency() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let calendar = Calendar.current
        let meetings = [
            meeting("오늘 것", at: now),
            meeting("어제 것", at: calendar.date(byAdding: .day, value: -1, to: now)!),
            meeting("사흘 전", at: calendar.date(byAdding: .day, value: -3, to: now)!),
            meeting("한 달 전", at: calendar.date(byAdding: .day, value: -30, to: now)!),
        ]
        let sections = MeetingList.sections(meetings, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["오늘", "어제", "이번 주", "이전"])
        #expect(sections.map { $0.meetings.count } == [1, 1, 1, 1])
    }

    @Test func flattensSectionsIntoRowsWithUniqueIDs() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let calendar = Calendar.current
        let meetings = [
            meeting("오늘 것", at: now),
            meeting("어제 것", at: calendar.date(byAdding: .day, value: -1, to: now)!),
        ]
        let rows = MeetingList.rows(meetings, now: now, calendar: calendar)
        #expect(rows.map(\.id).count == Set(rows.map(\.id)).count, "행 id가 겹친다")
        let titles = rows.map { row in
            switch row {
            case let .header(title): title
            case let .meeting(meeting): meeting.title
            }
        }
        #expect(titles == ["오늘", "오늘 것", "어제", "어제 것"])
    }

    @Test func searchesSummaryAndTranscript() {
        let now = Date()
        let meetings = [
            meeting("주간 회의", at: now, summary: "## 핵심\n- QR 스캔 정리"),
            meeting("스펙 리뷰", at: now, transcript: "[00:10] 나: 카메라 권한 이야기"),
            meeting("관계 없는 회의", at: now),
        ]
        #expect(MeetingList.filter(meetings, query: "QR").map(\.title) == ["주간 회의"])
        #expect(MeetingList.filter(meetings, query: "카메라").map(\.title) == ["스펙 리뷰"])
        #expect(MeetingList.filter(meetings, query: "  ").count == 3)
    }

    @Test func summaryPreviewStripsMarkers() {
        var meeting = Meeting(title: "회의")
        meeting.summary = "## 핵심 내용\n- 위젯 범위 합의 [04:12]"
        #expect(meeting.summaryPreview == "위젯 범위 합의 [04:12]")
        #expect(Meeting(title: "회의").summaryPreview == nil)
    }

    @Test func timecodesBecomePlayableLinks() {
        let linked = MeetingDocument.linkTimecodes(in: "- 범위 합의 [04:12]\n- 권한 [1:02:03]")
        #expect(linked.contains("[04:12](meeting-time:252)"))
        #expect(linked.contains("[1:02:03](meeting-time:3723)"))

        let url = try? #require(URL(string: "meeting-time:252"))
        #expect(MeetingDocument.seconds(fromLink: url!) == 252)
        #expect(MeetingDocument.seconds(fromLink: URL(string: "https://example.com")!) == nil)
    }

    @Test func leavesNonTimecodeBracketsAlone() {
        let text = "이미 [04:12](meeting-time:252) 이고 [메모] 와 [99] 는 그대로"
        #expect(MeetingDocument.linkTimecodes(in: text) == text)
    }
}

@Suite struct MeetingVaultExportTests {
    private func makeVault() throws -> (MeetingVaultExporter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)")
        let wiki = root.appendingPathComponent("wiki")
        try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
        return (MeetingVaultExporter(vaultRoot: root), root)
    }

    private func sample() -> Meeting {
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        return Meeting(title: "위젯 킥오프", startedAt: start,
                       endedAt: start.addingTimeInterval(600), status: .done,
                       segments: [TranscriptSegment(speaker: "나", start: 0, end: 4,
                                                    text: "시작하겠습니다")],
                       summary: "## 핵심 내용\n- 위젯 범위 합의")
    }

    @Test func writesTranscriptToRawAndSummaryToNotes() throws {
        let (exporter, root) = try makeVault()
        let written = try #require(try exporter.export(sample()))

        let note = try String(contentsOfFile: written.notePath, encoding: .utf8)
        let transcriptPath = try #require(written.transcriptPath)
        let transcript = try String(contentsOfFile: transcriptPath, encoding: .utf8)

        #expect(written.notePath.hasPrefix(root.appendingPathComponent("wiki/notes/meetings").path))
        #expect(transcriptPath.hasPrefix(root.appendingPathComponent("raw").path))
        #expect(note.contains("type: meeting-note"))
        #expect(note.contains("## 핵심 내용"))
        #expect(!note.contains("시작하겠습니다"), "전문이 노트에 들어가면 검색이 전사로 뒤덮인다")
        #expect(transcript.contains("시작하겠습니다"))
    }

    @Test func skipsMeetingWithoutSummaryOrTranscript() throws {
        let (exporter, _) = try makeVault()
        #expect(try exporter.export(Meeting(title: "빈 미팅")) == nil)
    }

    @Test func reexportOverwritesInsteadOfDuplicating() throws {
        let (exporter, root) = try makeVault()
        var meeting = sample()
        _ = try exporter.export(meeting)
        meeting.summary = "## 핵심 내용\n- 범위를 줄이기로"
        let second = try #require(try exporter.export(meeting))

        let notes = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("wiki/notes/meetings").path)
        #expect(notes.count == 1, "재내보내기가 사본을 남겼다")
        #expect(try String(contentsOfFile: second.notePath, encoding: .utf8)
            .contains("범위를 줄이기로"))
    }

    @Test func fullFlowRecordsVaultPathsAndDeleteReclaimsThem() async throws {
        let (exporter, _) = try makeVault()
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer(), vault: exporter)

        _ = try await center.startAdhocRecording(title: "위젯 킥오프")
        let done = try #require(try await center.stopRecording())

        let notePath = try #require(done.vaultNotePath)
        let transcriptPath = try #require(done.vaultTranscriptPath)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: notePath))
        #expect(fm.fileExists(atPath: transcriptPath))

        try await center.deleteMeeting(id: done.id)
        #expect(!fm.fileExists(atPath: notePath), "지운 미팅의 문서가 위키에 남았다")
        #expect(!fm.fileExists(atPath: transcriptPath))
    }

    @Test func renameMovesNoteToNewNameAndFixesLinks() async throws {
        let (exporter, root) = try makeVault()
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer(), vault: exporter)
        _ = try await center.startAdhocRecording(title: "위젯 킥오프")
        let done = try #require(try await center.stopRecording())
        let oldPath = try #require(done.vaultNotePath)
        let oldName = URL(fileURLWithPath: oldPath).lastPathComponent
        let linking = root.appendingPathComponent("wiki/notes/기획.md")
        try "본문 [킥오프](meetings/\(oldName))\n".write(to: linking, atomically: true, encoding: .utf8)

        try await center.renameMeeting(id: done.id, title: "위젯 킥오프 (수정)")

        let renamed = try #require(await center.meetings().first { $0.id == done.id })
        let newPath = try #require(renamed.vaultNotePath)
        let newName = URL(fileURLWithPath: newPath).lastPathComponent
        #expect(newName.contains("위젯-킥오프-수정"), "파일 이름이 옛 제목으로 남았다: \(newName)")
        #expect(!FileManager.default.fileExists(atPath: oldPath), "옛 이름의 노트가 남았다")
        let notes = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("wiki/notes/meetings").path)
        #expect(notes.count == 1, "제목을 고치자 노트가 새 이름으로 하나 더 생겼다")
        let note = try String(contentsOfFile: newPath, encoding: .utf8)
        #expect(note.contains("title: 위젯 킥오프 (수정)"))
        #expect(note.contains("# 위젯 킥오프 (수정)"))
        let link = try String(contentsOf: linking, encoding: .utf8)
        #expect(link.contains("meetings/\(newName)"), "옮긴 노트를 가리키던 링크가 끊겼다: \(link)")
    }

    @Test func renameMovesTranscriptAndKeepsNoteLinkValid() async throws {
        let (exporter, _) = try makeVault()
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer(), vault: exporter)
        _ = try await center.startAdhocRecording(title: "위젯 킥오프")
        let done = try #require(try await center.stopRecording())
        let oldTranscript = try #require(done.vaultTranscriptPath)

        try await center.renameMeeting(id: done.id, title: "위젯 킥오프 (수정)")

        let renamed = try #require(await center.meetings().first { $0.id == done.id })
        let newTranscript = try #require(renamed.vaultTranscriptPath)
        let newName = URL(fileURLWithPath: newTranscript).lastPathComponent
        #expect(newName.contains("위젯-킥오프-수정"))
        #expect(!FileManager.default.fileExists(atPath: oldTranscript), "옛 이름의 전사가 남았다")
        let note = try String(contentsOfFile: #require(renamed.vaultNotePath), encoding: .utf8)
        #expect(note.contains(newName), "노트의 전사 링크가 옛 이름을 가리킨다")
    }

    @Test func renamingSpeakerRewritesVaultTranscript() async throws {
        let (exporter, _) = try makeVault()
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(
                transcriber: TrackAwareTranscriber(byFile: ["fake.caf": [
                    TranscriptSegment(speaker: "나", start: 0, end: 4, text: "시작하겠습니다"),
                ]]),
                probe: FakeProbe(systemHasSpeech: false)),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer(), vault: exporter)
        _ = try await center.startAdhocRecording(title: "위젯 킥오프")
        let done = try #require(try await center.stopRecording())
        let transcriptPath = try #require(done.vaultTranscriptPath)

        try await center.renameSpeaker(meetingID: done.id, label: "나", name: "이서준")

        let transcript = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        #expect(transcript.contains("이서준"))
    }

    @Test func renameDoesNotExportUnfinishedMeeting() async throws {
        let (exporter, root) = try makeVault()
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(), transcription: nil,
                                   analyzer: nil, mixer: PassthroughMixer(), vault: exporter)
        let meeting = Meeting(title: "예정 미팅", status: .scheduled,
                              summary: "## 핵심 내용\n- 아직 없음")
        try await store.upsert(.meeting, meeting)

        try await center.renameMeeting(id: meeting.id, title: "예정 미팅 (수정)")

        let notes = root.appendingPathComponent("wiki/notes/meetings")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: notes.path))?.isEmpty ?? true)
    }

    @Test func summaryBodyStripsWrapperWrittenByExporter() throws {
        let (exporter, _) = try makeVault()
        let meeting = sample()
        let note = exporter.noteDocument(meeting, transcriptName: "meeting-x.md")
        #expect(MeetingVaultExporter.summaryBody(ofNote: note) == meeting.summary)
    }

    @Test func summaryBodyIsNilWhenBodyIsEmptied() throws {
        let note = """
        ---
        type: meeting-note
        ---

        # 제목만 남은 노트

        """
        #expect(MeetingVaultExporter.summaryBody(ofNote: note) == nil)
    }

    @Test func removeReclaimsBothFiles() throws {
        let (exporter, _) = try makeVault()
        let written = try #require(try exporter.export(sample()))
        exporter.remove(notePath: written.notePath, transcriptPath: written.transcriptPath)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: written.notePath))
        #expect(!fm.fileExists(atPath: written.transcriptPath ?? ""))
    }
}

@Suite struct DiarizationSetupTests {
    @Test func bundlesDiarizationScript() throws {
        let url = try #require(DiarizationSetup.bundledScriptURL)
        #expect(url.lastPathComponent == "diarize.py")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("MEETING_DIARIZATION_ROOT"), "스크립트가 호스트가 넘긴 설치 루트를 읽어야 한다")
    }

    @Test func reportsMissingPiecesByName() {
        let root = URL(fileURLWithPath: "/tmp/없는-루트-\(UUID().uuidString)")
        let setup = DiarizationSetup(supportRoot: root, script: nil)
        #expect(!setup.isReady)
        #expect(setup.scriptPath == nil)
        #expect(setup.missing.contains { $0.contains("diarize.py") })
        #expect(setup.missing.contains { $0.contains("venv") })
        #expect(setup.summary.contains("미설치"))
        #expect(setup.installHint.contains(root.path))
    }
}

@Suite struct TranscriptMergerTests {
    @Test func assignsSpeakerWithLargestOverlap() {
        let transcript = [
            TranscriptSegment(start: 0, end: 4, text: "안녕하세요"),
            TranscriptSegment(start: 4, end: 9, text: "네 반갑습니다"),
        ]
        let diarization = [
            TranscriptSegment(speaker: "S1", start: 0, end: 4.5, text: ""),
            TranscriptSegment(speaker: "S2", start: 4.5, end: 10, text: ""),
        ]
        let merged = TranscriptMerger.merge(transcript: transcript, diarization: diarization)
        #expect(merged[0].speaker == "S1")
        #expect(merged[1].speaker == "S2")
    }

    @Test func keepsTranscriptWhenNoDiarization() {
        let transcript = [TranscriptSegment(start: 0, end: 1, text: "테스트")]
        let merged = TranscriptMerger.merge(transcript: transcript, diarization: [])
        #expect(merged == transcript)
    }

    @Test func plainTextIncludesTimeAndSpeaker() {
        let text = TranscriptMerger.plainText([
            TranscriptSegment(speaker: "S1", start: 65, end: 70, text: "진행합시다"),
        ])
        #expect(text == "[01:05] S1: 진행합시다")
    }
}

@Suite struct AudioMixerTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTone(to url: URL, frequency: Double, seconds: Double = 0.5) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                       AVSampleRateKey: sampleRate,
                       AVNumberOfChannelsKey: 1,
                       AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true,
                       AVLinearPCMIsNonInterleaved: false])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] =
                Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        try file.write(from: buffer)
    }

    @Test func mixesBothTracksIntoNewFile() async throws {
        let dir = try makeDir()
        let system = dir.appendingPathComponent("system.caf")
        let mic = dir.appendingPathComponent("mic.caf")
        try writeTone(to: system, frequency: 440)
        try writeTone(to: mic, frequency: 880)

        let mixed = try await AVFoundationAudioMixer()
            .mixForTranscription(system: system, mic: mic)

        let url = try #require(mixed)
        #expect(url != system && url != mic, "두 트랙이 있으면 합성 파일을 새로 만든다")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 0.4, "합성 결과에 오디오가 담겨야 한다")
    }

    @Test func passesThroughWhenOnlyOneFile() async throws {
        let mic = URL(fileURLWithPath: "/tmp/only-mic.caf")
        let mixer = AVFoundationAudioMixer()
        let single = try await mixer.mixForTranscription(system: nil, mic: mic)
        #expect(single == mic, "한쪽만 있으면 합성 없이 그대로")
        let none = try await mixer.mixForTranscription(system: nil, mic: nil)
        #expect(none == nil)
    }

    @Test func fallsBackToReadableTrackWhenOtherIsBroken() async throws {
        let dir = try makeDir()
        let broken = dir.appendingPathComponent("system.mov")
        try Data("오디오 아님".utf8).write(to: broken)
        let mic = dir.appendingPathComponent("mic.caf")
        try writeTone(to: mic, frequency: 440)

        let result = try await AVFoundationAudioMixer()
            .mixForTranscription(system: broken, mic: mic)

        #expect(result == mic, "읽을 수 없는 트랙은 건너뛰고 남은 쪽을 쓴다")
    }
}

struct MeddlingTranscriber: Transcribing {
    let meddle: @Sendable () async -> Void

    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        await meddle()
        return [TranscriptSegment(start: 0, end: 3, text: "위젯 개선 건 논의")]
    }
}

@Suite struct MeetingCenterTests {
    @Test func renameDuringTranscriptionIsNotClobbered() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let box = CenterBox()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: MeddlingTranscriber {
                try? await box.center?.renameMeeting(id: box.meetingID ?? "",
                                                     title: "스프린트 계획 회의")
            }),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        box.center = center

        let meeting = try await center.startAdhocRecording(title: "미팅 7월 10일 15:00")
        box.meetingID = meeting.id
        _ = try await center.stopRecording()

        let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored?.title == "스프린트 계획 회의", "처리 중 바뀐 제목이 옛 사본에 덮였다")
        #expect(stored?.transcript.isEmpty == false, "전사 결과는 그대로 저장된다")
        #expect(stored?.status == .done)
    }

    @Test func deleteDuringTranscriptionIsNotResurrected() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let box = CenterBox()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: MeddlingTranscriber {
                try? await box.center?.deleteMeeting(id: box.meetingID ?? "")
            }),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        box.center = center

        let meeting = try await center.startAdhocRecording(title: "잘못 시작한 녹음")
        box.meetingID = meeting.id
        _ = try await center.stopRecording()

        let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored == nil, "삭제된 미팅이 처리 결과 쓰기로 되살아났다")
    }

    @Test func concurrentStartRecordsOnlyOneMeeting() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let recorder = FakeRecorder()
        let center = MeetingCenter(store: store, recorder: recorder,
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())

        async let first = try? center.startAdhocRecording(title: "미팅 A")
        async let second = try? center.startAdhocRecording(title: "미팅 B")
        let started = await [first, second].compactMap { $0 }

        #expect(started.count == 1, "두 번째 시작이 거부되지 않았다")
        #expect(recorder.started.count == 1, "녹음기가 두 번 켜졌다")
        let stored = await store.fetchAll(.meeting, as: Meeting.self)
        #expect(stored.count == 1, "진 쪽의 '예정' 유령 미팅이 남았다")
        #expect(stored.first?.status == .recording)
    }

    @Test func concurrentFinishStopsRecorderOnce() async throws {
        final class SlowRecorder: MeetingRecording, @unchecked Sendable {
            private let lock = NSLock()
            private var _stopped = 0
            var stopped: Int { lock.withLock { _stopped } }

            func start(meetingID: String) async throws {}
            func stop() async throws -> RecordedAudio {
                try? await Task.sleep(nanoseconds: 20_000_000)
                lock.withLock { _stopped += 1 }
                return RecordedAudio(systemAudioURL: URL(fileURLWithPath: "/tmp/fake.mov"),
                                     micURL: nil)
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let recorder = SlowRecorder()
        let center = MeetingCenter(store: store, recorder: recorder,
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        _ = try await center.startAdhocRecording(title: "미팅")

        async let first = try? center.finishRecording()
        async let second = try? center.finishRecording()
        let finished = await [first, second].compactMap { $0 }.compactMap { $0 }

        #expect(finished.count == 1, "두 번째 종료가 거부되지 않았다")
        #expect(recorder.stopped == 1, "녹음기를 두 번 멈췄다")
    }

    @Test func deleteRefusedWhileRecorderIsStopping() async throws {
        final class SlowRecorder: MeetingRecording, @unchecked Sendable {
            func start(meetingID: String) async throws {}
            func stop() async throws -> RecordedAudio {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return RecordedAudio(systemAudioURL: URL(fileURLWithPath: "/tmp/fake.mov"),
                                     micURL: nil)
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: SlowRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let meeting = try await center.startAdhocRecording(title: "미팅")

        async let finishing = try? center.finishRecording()
        try? await Task.sleep(nanoseconds: 5_000_000)
        try await center.deleteMeeting(id: meeting.id)
        _ = await finishing

        let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored != nil, "종료 처리 중 삭제가 통과했다")
        #expect(stored?.status == .transcribing)
    }

    @Test func deleteRemovesStaleRecordingRowFromPreviousLaunch() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let stale = Meeting(title: "크래시 잔재", status: .recording)
        try await store.upsert(.meeting, stale)

        try await center.deleteMeeting(id: stale.id)

        let stored = await store.fetch(.meeting, id: stale.id, as: Meeting.self)
        #expect(stored == nil, "재시작 후에도 지울 수 없는 유령 미팅이 남는다")
    }

    @Test func recoveryFailsInterruptedMeetingsButKeepsFinishedOnes() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let interrupted = [Meeting(title: "녹음 중", status: .recording),
                           Meeting(title: "전사 중", status: .transcribing),
                           Meeting(title: "요약 중", status: .summarizing)]
        let kept = [Meeting(title: "완료", status: .done),
                    Meeting(title: "실패", status: .failed)]
        for meeting in interrupted + kept { try await store.upsert(.meeting, meeting) }

        await center.recoverInterruptedMeetings()

        for meeting in interrupted {
            let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
            #expect(stored?.status == .failed, "\(meeting.title)이 진행 중으로 남았다")
            #expect(stored?.failureReason != nil)
            #expect(stored?.title == meeting.title, "복구가 제목을 건드리면 안 된다")
        }
        for meeting in kept {
            let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
            #expect(stored?.status == meeting.status, "끝난 미팅은 건드리지 않는다")
        }
    }

    @Test func recoveryIsNoOpWhileRecording() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let meeting = try await center.startAdhocRecording(title: "진행 중 녹음")

        await center.recoverInterruptedMeetings()

        let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored?.status == .recording)
    }

    func makeCenter() throws -> (MeetingCenter, SQLiteMeetingStore, FakeRecorder) {
        let store = try SQLiteMeetingStore.inMemory()
        let recorder = FakeRecorder()
        let center = MeetingCenter(
            store: store, recorder: recorder,
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        return (center, store, recorder)
    }

    @Test func fullFlowProducesSummaryAndTranscriptOnly() async throws {
        let (center, store, recorder) = try makeCenter()

        _ = try await center.startAdhocRecording(title: "위젯 킥오프")
        #expect(recorder.started.count == 1)

        let finished = try await center.stopRecording()
        #expect(finished?.status == .done)
        #expect(finished?.transcript.contains("위젯 개선 건") == true)
        #expect(finished?.summary == "## 핵심 내용\n- 위젯 개선 논의")
        #expect(finished?.mixedAudioPath != nil, "재생 파일 경로가 저장된다")
    }

    @Test func finishRecordingShowsTranscribingBeforeProcessing() async throws {
        let (center, store, recorder) = try makeCenter()
        _ = try await center.startAdhocRecording(title: "미팅")

        let finished = try #require(try await center.finishRecording())

        #expect(recorder.stopped == 1)
        let recording = await center.isRecording
        #expect(recording == false, "종료 즉시 새 녹음을 시작할 수 있다")
        let stored = await store.fetch(.meeting, id: finished.meeting.id, as: Meeting.self)
        #expect(stored?.status == .transcribing, "전사·요약 전에 이미 '정리 중'으로 보인다")

        let done = try await center.processRecording(finished)
        #expect(done?.status == .done)
    }

    @Test func reprocessRunsTranscriptionAgainOnFailedMeeting() async throws {
        let (center, store, _) = try makeCenter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        try Data("audio".utf8).write(to: mic)
        let meeting = Meeting(title: "실패 미팅", status: .failed, micAudioPath: mic.path,
                              failureReason: "전사 실패: 깨진 JSON")
        try await store.upsert(.meeting, meeting)

        let prepared = try #require(try await center.prepareReprocess(meetingID: meeting.id))
        let mid = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(mid?.status == .transcribing, "처리 전에 이미 '정리 중'으로 보인다")
        #expect(mid?.failureReason == nil, "직전 실패 사유는 지운다")

        let again = try await center.prepareReprocess(meetingID: meeting.id)
        #expect(again == nil)

        let done = try await center.processRecording(prepared)
        #expect(done?.status == .done)
        #expect(done?.transcript.contains("위젯 개선 건") == true)
    }

    @Test func reprocessRefusedWhenAudioFilesAreGone() async throws {
        let (center, store, _) = try makeCenter()
        let meeting = Meeting(title: "파일 없는 실패", status: .failed,
                              micAudioPath: "/tmp/없음-\(UUID().uuidString).caf",
                              failureReason: "전사 실패")
        try await store.upsert(.meeting, meeting)

        let prepared = try await center.prepareReprocess(meetingID: meeting.id)

        #expect(prepared == nil)
        let stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored?.status == .failed, "상태를 건드리지 않는다 — '정리 중' 유령 방지")
        #expect(stored?.failureReason == "전사 실패")
    }

    @Test func reprocessRefusedUnlessFailed() async throws {
        let (center, _, _) = try makeCenter()
        _ = try await center.startAdhocRecording(title: "정상 미팅")
        let done = try #require(try await center.stopRecording())

        let prepared = try await center.prepareReprocess(meetingID: done.id)
        #expect(prepared == nil)
    }

    @Test func recorderStartFailureMarksMeetingFailed() async throws {
        final class FailingRecorder: MeetingRecording, @unchecked Sendable {
            struct Denied: Error {}
            func start(meetingID: String) async throws { throw Denied() }
            func stop() async throws -> RecordedAudio {
                RecordedAudio(systemAudioURL: nil, micURL: nil)
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FailingRecorder(),
                                   transcription: nil, analyzer: nil)

        await #expect(throws: Error.self) {
            try await center.startAdhocRecording(title: "권한 없음")
        }
        let meetings = await store.fetchAll(.meeting, as: Meeting.self)
        #expect(meetings.count == 1)
        #expect(meetings.first?.status == .failed)
        #expect(meetings.first?.failureReason?.contains("녹음 시작 실패") == true)
        let recording = await center.isRecording
        #expect(recording == false)
    }

    @Test func deleteMeetingRemovesAudioFiles() async throws {
        let (center, store, _) = try makeCenter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let system = dir.appendingPathComponent("m-system.mov")
        let mic = dir.appendingPathComponent("m-mic.caf")
        let mixed = dir.appendingPathComponent("m-system.mixed.m4a")
        for url in [system, mic, mixed] { try Data("녹음".utf8).write(to: url) }
        let meeting = Meeting(title: "정리 대상", systemAudioPath: system.path,
                              micAudioPath: mic.path, mixedAudioPath: mixed.path)
        try await store.upsert(.meeting, meeting)

        try await center.deleteMeeting(id: meeting.id)

        let meetings = await store.fetchAll(.meeting, as: Meeting.self)
        #expect(meetings.isEmpty)
        for url in [system, mic, mixed] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "녹음 파일도 함께 삭제된다")
        }
    }

    @Test func renameMeetingUpdatesTitleAndRejectsEmpty() async throws {
        let (center, store, _) = try makeCenter()
        let meeting = Meeting(title: "미팅 7월 10일 14:30")
        try await store.upsert(.meeting, meeting)

        try await center.renameMeeting(id: meeting.id, title: "  위젯 킥오프  ")
        var stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored?.title == "위젯 킥오프", "앞뒤 공백은 정리해 저장한다")

        try await center.renameMeeting(id: meeting.id, title: "   ")
        stored = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(stored?.title == "위젯 킥오프", "공백뿐인 제목은 무시한다")
    }

    @Test func mixedAudioPathPersistsWithoutTranscription() async throws {
        struct FixedMixer: AudioMixing {
            let url: URL
            func mixForTranscription(system: URL?, mic: URL?,
                                     micStartOffset: TimeInterval) async throws -> URL? { url }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let mixedURL = URL(fileURLWithPath: "/tmp/mixed-fixed.m4a")
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil,
                                   mixer: FixedMixer(url: mixedURL))

        _ = try await center.startAdhocRecording(title: "전사 없음")
        let finished = try await center.stopRecording()

        #expect(finished?.status == .done)
        #expect(finished?.mixedAudioPath == mixedURL.path)
        #expect(finished?.transcript.isEmpty == true)
    }

    @Test func summaryFailureMarksMeetingFailedAndKeepsTranscript() async throws {
        struct FailingAnalyzer: MeetingSummarizing {
            struct Down: Error {}
            func summarize(prompt: String, title: String) async throws -> MeetingSummary { throw Down() }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: FailingAnalyzer(), mixer: PassthroughMixer())

        _ = try await center.startAdhocRecording(title: "요약이 죽은 미팅")
        let finished = try await center.stopRecording()

        #expect(finished?.status == .failed)
        #expect(finished?.failureReason?.contains("요약 실패") == true)
        #expect(finished?.transcript.contains("위젯 개선 건") == true,
                "요약만 실패했으므로 전사는 남아야 한다")
    }

    @Test func emptySummaryIsFailureNotSilentDone() async throws {
        struct BlankAnalyzer: MeetingSummarizing {
            func summarize(prompt: String, title: String) async throws -> MeetingSummary {
                MeetingSummary(summary: "   \n  ")
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FakeTranscriber()),
            analyzer: BlankAnalyzer(), mixer: PassthroughMixer())

        _ = try await center.startAdhocRecording(title: "빈 요약")
        let finished = try await center.stopRecording()

        #expect(finished?.status == .failed)
        #expect(finished?.failureReason?.contains("비어 있") == true)
    }

    @Test func reprocessAfterSummaryFailureSkipsTranscription() async throws {
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        let mixed = dir.appendingPathComponent("mixed.m4a")
        for url in [mic, mixed] { try Data("녹음".utf8).write(to: url) }
        let meeting = Meeting(
            title: "요약만 실패", status: .failed, micAudioPath: mic.path,
            mixedAudioPath: mixed.path,
            segments: [TranscriptSegment(start: 0, end: 4, text: "이미 전사된 내용")],
            transcript: "[00:00] 이미 전사된 내용",
            failureReason: "요약 실패: 세션이 죽었습니다.")
        try await store.upsert(.meeting, meeting)

        let prepared = try #require(try await center.prepareReprocess(meetingID: meeting.id))
        let done = try await center.processRecording(prepared)

        #expect(transcriber.calls == 0, "전사가 다시 돌았다")
        #expect(done?.status == .done)
        #expect(done?.transcript.contains("이미 전사된 내용") == true, "기존 전사가 보존된다")
        #expect(done?.summary.isEmpty == false)
    }

    @Test func reprocessAfterTranscriptionFailureRunsTranscriptionAgain() async throws {
        final class CountingTranscriber: Transcribing, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.withLock { _calls } }
            func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
                lock.withLock { _calls += 1 }
                return [TranscriptSegment(start: 0, end: 3, text: "더 좋은 모델로 다시 전사")]
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let transcriber = CountingTranscriber()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: transcriber),
            analyzer: FakeAnalyzer(), mixer: PassthroughMixer())

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retranscribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        let mixed = dir.appendingPathComponent("mixed.m4a")
        for url in [mic, mixed] { try Data("녹음".utf8).write(to: url) }
        let meeting = Meeting(
            title: "전사가 나빴던 미팅", status: .failed, micAudioPath: mic.path,
            mixedAudioPath: mixed.path,
            segments: [TranscriptSegment(start: 0, end: 4, text: "옛 모델의 엉망 전사")],
            transcript: "[00:00] 옛 모델의 엉망 전사",
            failureReason: "전사 실패: 깨진 JSON")
        try await store.upsert(.meeting, meeting)

        let prepared = try #require(try await center.prepareReprocess(meetingID: meeting.id))
        let done = try await center.processRecording(prepared)

        #expect(transcriber.calls == 1, "전사를 다시 돌리지 않았다")
        #expect(done?.transcript.contains("다시 전사") == true)
    }

    @Test func doneMeetingCanBeForcedToTranscribeAgain() async throws {
        final class CountingTranscriber: Transcribing, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int { lock.withLock { _calls } }
            func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
                lock.withLock { _calls += 1 }
                return [TranscriptSegment(start: 0, end: 3, text: "2패스까지 붙은 새 전사")]
            }
        }
        func makeDoneMeeting(_ store: SQLiteMeetingStore) async throws -> Meeting {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("force-retranscribe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let mic = dir.appendingPathComponent("mic.caf")
            let mixed = dir.appendingPathComponent("mixed.m4a")
            for url in [mic, mixed] { try Data("녹음".utf8).write(to: url) }
            let meeting = Meeting(
                title: "58%만 전사된 미팅", status: .done, micAudioPath: mic.path,
                mixedAudioPath: mixed.path,
                segments: [TranscriptSegment(start: 0, end: 4, text: "구멍 뚫린 옛 전사")],
                transcript: "[00:00] 구멍 뚫린 옛 전사", summary: "옛 요약")
            try await store.upsert(.meeting, meeting)
            return meeting
        }
        func makeCenter(_ store: SQLiteMeetingStore, _ transcriber: Transcribing) -> MeetingCenter {
            MeetingCenter(store: store, recorder: FakeRecorder(),
                          transcription: LocalTranscriptionPipeline(transcriber: transcriber),
                          analyzer: FakeAnalyzer(), mixer: PassthroughMixer())
        }

        let store = try SQLiteMeetingStore.inMemory()
        let transcriber = CountingTranscriber()
        let meeting = try await makeDoneMeeting(store)
        let prepared = try #require(try await makeCenter(store, transcriber)
            .prepareReprocess(meetingID: meeting.id, summaryOnly: false))
        #expect(prepared.meeting.status == .transcribing)
        let done = try await makeCenter(store, transcriber).processRecording(prepared)
        #expect(transcriber.calls == 1, "전사를 다시 돌리지 않았다")
        #expect(done?.transcript.contains("새 전사") == true)

        let store2 = try SQLiteMeetingStore.inMemory()
        let transcriber2 = CountingTranscriber()
        let meeting2 = try await makeDoneMeeting(store2)
        let prepared2 = try #require(try await makeCenter(store2, transcriber2)
            .prepareReprocess(meetingID: meeting2.id))
        #expect(prepared2.meeting.status == .summarizing)
        _ = try await makeCenter(store2, transcriber2).processRecording(prepared2)
        #expect(transcriber2.calls == 0, "기본값에서 전사가 다시 돌았다")
    }

    @Test func playbackURLFallbackChain() {
        var meeting = Meeting(title: "재생", systemAudioPath: "/rec/a-system.mov",
                              micAudioPath: "/rec/a-mic.caf",
                              mixedAudioPath: "/rec/a-system.mixed.m4a")
        #expect(meeting.playbackURL { _ in true }?.path == "/rec/a-system.mixed.m4a")
        meeting.mixedAudioPath = nil
        #expect(meeting.playbackURL { $0 == "/rec/a-system.mixed.m4a" }?.path
            == "/rec/a-system.mixed.m4a")
        #expect(meeting.playbackURL { $0 == "/rec/a-mic.caf" }?.path == "/rec/a-mic.caf")
        #expect(meeting.playbackURL { $0 == "/rec/a-system.mov" }?.path == "/rec/a-system.mov")
        #expect(meeting.playbackURL { _ in false } == nil)
    }

    @Test func meterLevelClampsAndScales() {
        #expect(SystemAudioMeetingRecorder.meterLevel(rms: 0) == 0)
        #expect(SystemAudioMeetingRecorder.meterLevel(rms: 1) == 1)
        #expect(SystemAudioMeetingRecorder.meterLevel(rms: 0.001) == 0, "-60dB는 0으로 클램프")
        let mid = SystemAudioMeetingRecorder.meterLevel(rms: 0.05)
        #expect(mid > 0.3 && mid < 0.7, "중간 음량은 중간 레벨로")
        #expect(SystemAudioMeetingRecorder.meterLevel(rms: 2) == 1, "0dB 초과도 1로 클램프")
    }

    @Test func deleteMeetingRefusesActiveRecording() async throws {
        let (center, store, _) = try makeCenter()
        let meeting = try await center.startAdhocRecording(title: "녹음 중")

        try await center.deleteMeeting(id: meeting.id)

        let kept = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(kept != nil)
        _ = try await center.stopRecording()
    }

    @Test func pauseOutsideRecordingIsIgnored() async throws {
        let (center, _, recorder) = try makeCenter()

        await center.pauseRecording()
        await center.resumeRecording()

        #expect(recorder.pausedStates.isEmpty)
        #expect(await center.isPaused == false)
    }

    @Test func pauseAndResumeReachRecorderOnce() async throws {
        let (center, _, recorder) = try makeCenter()
        _ = try await center.startAdhocRecording(title: "쉬는 시간")

        await center.pauseRecording()
        await center.pauseRecording()
        #expect(await center.isPaused)
        #expect(await center.isRecording, "일시 중지는 여전히 녹음 세션이다")

        await center.resumeRecording()
        await center.resumeRecording()
        #expect(await center.isPaused == false)
        #expect(recorder.pausedStates == [true, false], "같은 상태로 두 번 부르면 녹음기에 안 간다")
        _ = try await center.stopRecording()
    }

    @Test func finishingWhilePausedRecordsPausedSeconds() async throws {
        let (center, store, recorder) = try makeCenter()
        let meeting = try await center.startAdhocRecording(title: "쉬는 시간")
        let base = Date()

        await center.pauseRecording(at: base.addingTimeInterval(60))
        await center.resumeRecording(at: base.addingTimeInterval(90))
        await center.pauseRecording(at: base.addingTimeInterval(120))
        let end = base.addingTimeInterval(180)
        let finished = try #require(try await center.finishRecording(at: end))

        #expect(recorder.stopped == 1)
        #expect(finished.meeting.endedAt == end)
        #expect(finished.meeting.pausedSeconds == 90, "열린 구간은 종료 시각까지 센다")
        #expect(await center.isPaused == false, "종료하면 장부가 비워진다")
        #expect(await center.recordingPause == RecordingPause())

        let stored = try #require(await store.fetch(.meeting, id: meeting.id, as: Meeting.self))
        #expect(stored.pausedSeconds == 90)
        #expect(stored.status == .transcribing)
    }

    @Test func pauseDuringFinishIsIgnored() async throws {
        final class SlowRecorder: MeetingRecording, @unchecked Sendable {
            private let lock = NSLock()
            private var _pausedStates: [Bool] = []
            var pausedStates: [Bool] { lock.withLock { _pausedStates } }

            func start(meetingID: String) async throws {}
            func stop() async throws -> RecordedAudio {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return RecordedAudio(systemAudioURL: URL(fileURLWithPath: "/tmp/fake.mov"),
                                     micURL: nil)
            }
            func setPaused(_ paused: Bool) { lock.withLock { _pausedStates.append(paused) } }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let recorder = SlowRecorder()
        let center = MeetingCenter(store: store, recorder: recorder,
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        _ = try await center.startAdhocRecording(title: "미팅")

        async let finishing = try? center.finishRecording()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await center.pauseRecording()
        let finished = await finishing

        #expect(finished != nil)
        #expect(recorder.pausedStates.isEmpty, "종료 중에 들어온 일시 중지는 장부를 건드리면 안 된다")
        #expect(await center.isPaused == false)
    }

    @Test func deleteMeetingRefusedWhilePaused() async throws {
        let (center, store, _) = try makeCenter()
        let meeting = try await center.startAdhocRecording(title: "쉬는 중")
        await center.pauseRecording()

        try await center.deleteMeeting(id: meeting.id)

        let kept = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(kept != nil, "일시 중지 중에도 활성 미팅이다")
        _ = try await center.stopRecording()
    }

    @Test func pauseBeforeRecorderStartsStaysPaused() async throws {
        final class SlowStartRecorder: MeetingRecording, @unchecked Sendable {
            private let lock = NSLock()
            private var _pausedStates: [Bool] = []
            var pausedStates: [Bool] { lock.withLock { _pausedStates } }

            func start(meetingID: String) async throws {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            func stop() async throws -> RecordedAudio {
                RecordedAudio(systemAudioURL: URL(fileURLWithPath: "/tmp/fake.mov"), micURL: nil)
            }
            func setPaused(_ paused: Bool) { lock.withLock { _pausedStates.append(paused) } }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let recorder = SlowStartRecorder()
        let center = MeetingCenter(store: store, recorder: recorder,
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())

        async let starting = try? center.startAdhocRecording(title: "미팅")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await center.pauseRecording()
        _ = await starting

        #expect(await center.isRecording)
        #expect(await center.isPaused, "시작 직후 누른 일시 중지는 시작이 끝나도 살아 있다")
        #expect(recorder.pausedStates == [true])
        _ = try await center.stopRecording()
    }

    @Test func failedStartClearsPauseLedger() async throws {
        final class FailingRecorder: MeetingRecording, @unchecked Sendable {
            struct Denied: Error {}
            func start(meetingID: String) async throws {
                try? await Task.sleep(nanoseconds: 30_000_000)
                throw Denied()
            }
            func stop() async throws -> RecordedAudio { fatalError("unused") }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FailingRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())

        async let starting = try? center.startAdhocRecording(title: "미팅")
        try? await Task.sleep(nanoseconds: 5_000_000)
        await center.pauseRecording()
        _ = await starting

        #expect(await center.isRecording == false)
        #expect(await center.isPaused == false, "시작이 실패하면 장부도 비운다")
    }

    @Test func transcriptionFailureMarksMeetingFailed() async throws {
        struct FailingTranscriber: Transcribing {
            func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
                throw ProcessError.launchFailed("whisper 미설치")
            }
        }
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(
            store: store, recorder: FakeRecorder(),
            transcription: LocalTranscriptionPipeline(transcriber: FailingTranscriber()),
            analyzer: nil, mixer: PassthroughMixer())

        _ = try await center.startAdhocRecording(title: "미팅")
        let finished = try await center.stopRecording()
        #expect(finished?.status == .failed)
        #expect(finished?.failureReason?.contains("전사 실패") == true)
    }
}

struct FakeProbe: TrackProbing {
    var systemHasSpeech: Bool
    var trackDuration: TimeInterval?

    func hasSpeech(url: URL?) async -> Bool {
        url != nil && systemHasSpeech
    }

    func duration(url: URL?) async -> TimeInterval? {
        trackDuration
    }
}

struct FakeDiarizer: Diarizing {
    var turnsByFile: [String: [TranscriptSegment]] = [:]
    var failure: Error?

    func diarize(audioURL: URL) async throws -> [TranscriptSegment] {
        if let failure { throw failure }
        return turnsByFile[audioURL.lastPathComponent] ?? []
    }
}

struct TwoLineTranscriber: Transcribing {
    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(start: 0, end: 4, text: "이번 스펙 정리했습니다"),
            TranscriptSegment(start: 5, end: 9, text: "네 확인했습니다"),
            TranscriptSegment(start: 10, end: 14, text: "그럼 다음 주에 뵙겠습니다"),
        ]
    }
}

struct TrackAwareTranscriber: Transcribing {
    var byFile: [String: [TranscriptSegment]] = [:]

    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        byFile[audioURL.lastPathComponent] ?? []
    }
}

actor FakeLiveTranscriber: LiveTranscribing {
    private var listeners: [UUID: AsyncStream<LiveTranscriptUpdate>.Continuation] = [:]
    private(set) var started = false
    private(set) var stopped = false
    var finalDraft: [TranscriptSegment] = []

    init(finalDraft: [TranscriptSegment] = []) {
        self.finalDraft = finalDraft
    }

    func prewarm() async {}

    func start() async { started = true }

    func stop() async -> [TranscriptSegment] {
        stopped = true
        for listener in listeners.values { listener.finish() }
        listeners = [:]
        return finalDraft
    }

    nonisolated func updates() -> AsyncStream<LiveTranscriptUpdate> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ continuation: AsyncStream<LiveTranscriptUpdate>.Continuation) {
        listeners[UUID()] = continuation
    }

    func emit(_ update: LiveTranscriptUpdate) {
        for listener in listeners.values { listener.yield(update) }
    }

    func waitForListener() async {
        for _ in 0..<200 where listeners.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite struct LiveTranscriptionTests {
    private func center(store: SQLiteMeetingStore, live: FakeLiveTranscriber,
                        transcription: LocalTranscriptionPipeline?) -> MeetingCenter {
        MeetingCenter(store: store, recorder: FakeRecorder(), transcription: transcription,
                      analyzer: FakeAnalyzer(), mixer: PassthroughMixer(), live: live)
    }

    private func eventually(_ store: SQLiteMeetingStore, id: String,
                            _ satisfies: @Sendable (Meeting) -> Bool) async -> Meeting? {
        for _ in 0..<200 {
            if let meeting = await store.fetch(.meeting, id: id, as: Meeting.self),
               satisfies(meeting) {
                return meeting
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func confirmedLinesAreSavedWhileRecording() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let live = FakeLiveTranscriber()
        let center = center(store: store, live: live, transcription: nil)
        let meeting = try await center.startAdhocRecording(title: "라이브 미팅")
        await live.waitForListener()

        await live.emit(LiveTranscriptUpdate(
            confirmed: [TranscriptSegment(speaker: "나", start: 0, end: 3, text: "시작하겠습니다")],
            pending: "그리고"))

        let saved = try #require(await eventually(store, id: meeting.id) { !$0.segments.isEmpty })
        #expect(saved.segments.map(\.text) == ["시작하겠습니다"])
        #expect(!saved.transcript.contains("그리고"), "미확정 꼬리는 저장하지 않는다")
    }

    @Test func finishKeepsLiveDraftBeforePreciseRun() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let live = FakeLiveTranscriber(finalDraft: [
            TranscriptSegment(speaker: "나", start: 0, end: 3, text: "초벌입니다"),
        ])
        let center = center(store: store, live: live, transcription: nil)
        let meeting = try await center.startAdhocRecording(title: "라이브 미팅")

        let finished = try #require(try await center.finishRecording())
        #expect(finished.meeting.status == .transcribing)
        #expect(finished.meeting.segments.map(\.text) == ["초벌입니다"])
        #expect(await live.stopped)
        _ = meeting
    }

    @Test func preciseTranscriptionReplacesLiveDraft() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let live = FakeLiveTranscriber(finalDraft: [
            TranscriptSegment(speaker: "나", start: 0, end: 3, text: "초벌입니다"),
        ])
        let center = center(store: store, live: live,
                            transcription: LocalTranscriptionPipeline(
                                transcriber: FakeTranscriber(),
                                probe: FakeProbe(systemHasSpeech: false)))
        _ = try await center.startAdhocRecording(title: "라이브 미팅")
        let done = try #require(try await center.stopRecording())

        #expect(done.segments.map(\.text) == ["위젯 개선 건 논의합시다", "다음 주까지 스펙 정리하겠습니다"])
        #expect(!done.transcript.contains("초벌입니다"))
    }

    @Test func silentLiveDoesNotAffectMeeting() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let live = FakeLiveTranscriber()
        let center = center(store: store, live: live,
                            transcription: LocalTranscriptionPipeline(
                                transcriber: FakeTranscriber(),
                                probe: FakeProbe(systemHasSpeech: false)))
        _ = try await center.startAdhocRecording(title: "라이브 미팅")
        let done = try #require(try await center.stopRecording())
        #expect(done.status == .done)
        #expect(!done.segments.isEmpty)
    }

    @Test func splitHoldsBackTheTailAndDropsOnlyWhatItConfirmed() {
        let segments = [
            TranscriptSegment(start: 10, end: 12, text: "확정된 말"),
            TranscriptSegment(start: 12, end: 14, text: "이어질 수 있는 말"),
        ]
        let split = LiveAudio.split(segments: segments, base: 10, full: false,
                                    sampleRate: 16_000, available: 16_000 * 4)
        #expect(split.confirmed.map(\.text) == ["확정된 말"])
        #expect(split.pending == "이어질 수 있는 말")
        #expect(split.drop == 16_000 * 2, "확정한 2초만 버려야 꼬리가 살아남는다")
    }

    @Test func splitConfirmsEverythingWhenWindowIsFull() {
        let segments = [TranscriptSegment(start: 0, end: 27.5, text: "긴 말")]
        let split = LiveAudio.split(segments: segments, base: 0, full: true,
                                    sampleRate: 16_000, available: 16_000 * 28)
        #expect(split.confirmed.count == 1)
        #expect(split.pending.isEmpty)
        #expect(split.drop == Int(27.5 * 16_000))
    }

    @Test func splitOnEmptySegments() {
        let idle = LiveAudio.split(segments: [], base: 0, full: false,
                                   sampleRate: 16_000, available: 999)
        #expect(idle.drop == 0)
        let full = LiveAudio.split(segments: [], base: 0, full: true,
                                   sampleRate: 16_000, available: 999)
        #expect(full.drop == 999)
    }

    @Test func monoDownmixHandlesBothLayouts() throws {
        for interleaved in [true, false] {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 48_000, channels: 2,
                                                    interleaved: interleaved))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            buffer.frameLength = 2
            let data = try #require(buffer.floatChannelData)
            if interleaved {
                data[0][0] = 1; data[0][1] = 0
                data[0][2] = 0; data[0][3] = 1
            } else {
                data[0][0] = 1; data[0][1] = 0
                data[1][0] = 0; data[1][1] = 1
            }
            #expect(LiveAudio.monoSamples(of: buffer) == [0.5, 0.5])
        }
    }

    @Test func liveSaveDoesNotResurrectDeletedMeeting() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let live = FakeLiveTranscriber()
        let center = center(store: store, live: live, transcription: nil)
        let meeting = try await center.startAdhocRecording(title: "라이브 미팅")
        await live.waitForListener()
        try await store.delete(.meeting, id: meeting.id)

        await live.emit(LiveTranscriptUpdate(
            confirmed: [TranscriptSegment(speaker: "나", start: 0, end: 3, text: "시작하겠습니다")]))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await store.fetch(.meeting, id: meeting.id, as: Meeting.self) == nil)
    }
}

final class HintRecordingTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String?] = []

    var hints: [String?] { lock.withLock { seen } }

    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        lock.withLock { seen.append(hint) }
        return [TranscriptSegment(start: 0, end: 1, text: "한 줄")]
    }
}

@Suite struct AudioGainTests {
    private func speech(level: Float, noise: Float, seconds: Double = 4) -> [Float] {
        let count = Int(16_000 * seconds)
        return (0..<count).map { index in
            let loud = (index / 1600) % 4 == 0
            let amplitude = loud ? level : noise
            return index % 2 == 0 ? amplitude : -amplitude
        }
    }

    @Test func windowedGainLiftsTheQuietHalfThatOneScalarCannot() {
        let loud = speech(level: 0.30, noise: 0.03, seconds: 60)
        let faint = speech(level: 0.006, noise: 0.0006, seconds: 60)

        var single = loud + faint
        AudioGain.normalize(&single)
        var windowed = loud + faint
        AudioGain.normalizeWindowed(&windowed)

        let quietStart = loud.count + 16_000 * 10
        let singleQuiet = AudioGain.measure(Array(single[quietStart...])).speech
        let windowedQuiet = AudioGain.measure(Array(windowed[quietStart...])).speech

        #expect(windowedQuiet > singleQuiet * 3, "조용한 뒷부분이 그대로 남았다")
        #expect(windowedQuiet > 0.04, "목표(0.08) 근처까지 올라오지 않았다")
    }

    @Test func windowedGainNeverClips() {
        var samples = speech(level: 0.02, noise: 0.002, seconds: 90)
        AudioGain.normalizeWindowed(&samples)
        #expect(samples.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test func windowedGainRampsBetweenWindows() {
        let loud = speech(level: 0.30, noise: 0.03, seconds: 30)
        let faint = speech(level: 0.006, noise: 0.0006, seconds: 30)
        var samples = loud + faint
        AudioGain.normalizeWindowed(&samples, windowSeconds: 30)

        let before = AudioGain.measure(Array(samples[(16_000 * 29)..<(16_000 * 30)])).speech
        let after = AudioGain.measure(Array(samples[(16_000 * 30)..<(16_000 * 31)])).speech
        #expect(before > 0 && after > 0)
        #expect(after / before < 20, "경계에서 세기가 통째로 튀었다")
    }

    @Test func windowedGainFallsBackForShortAudio() {
        var windowed = speech(level: 0.02, noise: 0.002, seconds: 4)
        var single = windowed
        AudioGain.normalizeWindowed(&windowed)
        AudioGain.normalize(&single)
        #expect(windowed == single)
    }

    @Test func measureSeparatesSpeechFromNoiseFloor() {
        let level = AudioGain.measure(speech(level: 0.02, noise: 0.002))
        #expect(abs(level.speech - 0.02) < 0.002)
        #expect(abs(level.noise - 0.002) < 0.0005)
        #expect(level.peak > 0.015)
    }

    @Test func speechIsDetectedAtAnyDistance() {
        for attenuation: Float in [1, 0.25, 0.1, 0.03] {
            let samples = speech(level: 0.02 * attenuation, noise: 0.002 * attenuation)
            #expect(AudioGain.hasSpeech(AudioGain.measure(samples)),
                    "\(attenuation)배 거리에서 말을 놓쳤다")
        }
    }

    @Test func silenceIsRejected() {
        #expect(!AudioGain.hasSpeech(AudioGain.measure(speech(level: 0.004, noise: 0.003))))
        #expect(!AudioGain.hasSpeech(AudioGain.measure([Float](repeating: 0, count: 16_000))))
    }

    @Test func gainLiftsQuietSpeechWithoutClipping() {
        let samples = speech(level: 0.01, noise: 0.001)
        let gain = AudioGain.factor(for: AudioGain.measure(samples))
        #expect(gain > 3)
        let louder = AudioGain.amplified(samples, by: gain)
        #expect(louder.allSatisfy { abs($0) <= 1 })
        #expect(AudioGain.measure(louder).speech > 0.05)
    }

    @Test func loudEnoughAudioIsLeftAlone() {
        let samples = speech(level: 0.3, noise: 0.02)
        #expect(AudioGain.factor(for: AudioGain.measure(samples)) == 1)
        #expect(AudioGain.normalized(samples) == samples)
        var inPlace = samples
        AudioGain.normalize(&inPlace)
        #expect(inPlace == samples)
    }

    @Test func inPlaceNormalizeMatchesTheCopyingOne() {
        let samples = speech(level: 0.01, noise: 0.001)
        var inPlace = samples
        AudioGain.normalize(&inPlace)
        #expect(inPlace == AudioGain.normalized(samples))
    }

    @Test func noiseIsNotAmplified() {
        #expect(AudioGain.factor(for: AudioGain.measure(speech(level: 0.004, noise: 0.003))) == 1)
    }
}

@Suite struct TranscriptionHintTests {
    private func meeting(title: String, names: [String: String] = [:]) -> Meeting {
        var meeting = Meeting(title: title, scheduledAt: Date())
        meeting.speakerNames = names
        return meeting
    }

    @Test func hintCarriesTitleAndNamedSpeakers() {
        let hint = meeting(title: "팀 주간회의",
                           names: ["상대1": "이서준", "나": "한도윤"]).transcriptionHint
        #expect(hint == "팀 주간회의. 참석자: 이서준, 한도윤")
    }

    @Test func hintSkipsAutoLabelsAndBlankNames() {
        #expect(meeting(title: "스펙 리뷰", names: ["상대1": "  "]).transcriptionHint == "스펙 리뷰")
        #expect(meeting(title: "   ").transcriptionHint.isEmpty)
    }

    @Test func pipelineMergesGlossaryWithMeetingHint() async throws {
        let transcriber = HintRecordingTranscriber()
        let pipeline = LocalTranscriptionPipeline(
            transcriber: transcriber, probe: FakeProbe(systemHasSpeech: false),
            glossary: "온프레미스, QR 스캔")
        _ = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"), system: nil, mic: nil,
                                   hint: "팀 주간회의. 참석자: 이서준")
        #expect(transcriber.hints == ["팀 주간회의. 참석자: 이서준. 용어: 온프레미스, QR 스캔"])
    }

    @Test func pipelinePassesNoHintWhenNothingToSay() async throws {
        let transcriber = HintRecordingTranscriber()
        let pipeline = LocalTranscriptionPipeline(
            transcriber: transcriber, probe: FakeProbe(systemHasSpeech: false))
        _ = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"), system: nil, mic: nil,
                                   hint: "")
        #expect(transcriber.hints == [nil])
    }

    @Test func bothTracksGetTheSameHint() async throws {
        let transcriber = HintRecordingTranscriber()
        let pipeline = LocalTranscriptionPipeline(
            transcriber: transcriber, probe: FakeProbe(systemHasSpeech: true))
        _ = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.mixed.m4a"),
                                   system: URL(fileURLWithPath: "/tmp/m-system.mov"),
                                   mic: URL(fileURLWithPath: "/tmp/m-mic.caf"),
                                   hint: "팀 주간회의")
        #expect(transcriber.hints == ["팀 주간회의", "팀 주간회의"])
    }
}

@Suite struct SpeakerAttributionTests {
    private let mixed = URL(fileURLWithPath: "/tmp/m.mixed.m4a")
    private let system = URL(fileURLWithPath: "/tmp/m-system.mov")
    private let mic = URL(fileURLWithPath: "/tmp/m-mic.caf")

    @Test func onlineCallLabelsMicAsMeAndSystemAsOthers() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TrackAwareTranscriber(byFile: [
                "m-mic.caf": [TranscriptSegment(start: 0, end: 4, text: "이번 스펙 정리했습니다")],
                "m-system.mov": [
                    TranscriptSegment(start: 5, end: 9, text: "네 확인했습니다"),
                    TranscriptSegment(start: 10, end: 14, text: "그럼 다음 주에 뵙겠습니다"),
                ],
            ]),
            diarizer: FakeDiarizer(turnsByFile: ["m-system.mov": [
                TranscriptSegment(speaker: "S1", start: 4.5, end: 9.5, text: ""),
                TranscriptSegment(speaker: "S2", start: 9.5, end: 15, text: ""),
            ]]),
            probe: FakeProbe(systemHasSpeech: true))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.map(\.speaker) == ["나", "상대1", "상대2"])
        #expect(result.segments[0].text == "이번 스펙 정리했습니다")
        #expect(result.diarizationNote == nil)
    }

    @Test func micSegmentsShiftByStartOffset() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TrackAwareTranscriber(byFile: [
                "m-mic.caf": [TranscriptSegment(start: 0, end: 3, text: "제가 먼저 말합니다")],
                "m-system.mov": [TranscriptSegment(start: 1, end: 4, text: "상대가 이어 말합니다")],
            ]),
            diarizer: nil, probe: FakeProbe(systemHasSpeech: true))

        let shifted = try await pipeline.run(mixed: mixed, system: system, mic: mic,
                                             micStartOffset: 2.5)

        let mine = try #require(shifted.segments.first { $0.speaker == "나" })
        #expect(mine.start == 2.5, "마이크 시작 지연만큼 밀려야 한다")
        #expect(mine.end == 5.5)
        #expect(shifted.segments.map(\.speaker) == ["상대", "나"], "밀린 뒤 시간순으로 정렬된다")
    }

    @Test func offlineMeetingNumbersSpeakersWithoutClaimingMe() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TwoLineTranscriber(),
            diarizer: FakeDiarizer(turnsByFile: ["m-mic.caf": [
                TranscriptSegment(speaker: "S1", start: 0, end: 4.5, text: ""),
                TranscriptSegment(speaker: "S2", start: 4.5, end: 9.5, text: ""),
                TranscriptSegment(speaker: "S1", start: 9.5, end: 15, text: ""),
            ]]),
            probe: FakeProbe(systemHasSpeech: false))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.map(\.speaker) == ["화자1", "화자2", "화자1"])
        #expect(result.segments.allSatisfy { $0.speaker != "나" }, "대면에서는 나를 억측하지 않는다")
    }

    @Test func diarizationFailureIsReportedNotSwallowed() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TwoLineTranscriber(),
            diarizer: FakeDiarizer(failure: ProcessError.launchFailed("python3 없음")),
            probe: FakeProbe(systemHasSpeech: false))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.allSatisfy { $0.speaker == nil }, "라벨 없이 전사는 남는다")
        #expect(result.diarizationNote?.contains("실패") == true)
    }

    @Test func missingDiarizerIsReported() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TwoLineTranscriber(), diarizer: nil,
            probe: FakeProbe(systemHasSpeech: false))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.diarizationNote?.contains("설정되지 않아") == true)
    }

    @Test func onlineCallSplitsMeAndOtherWithoutDiarizer() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: TrackAwareTranscriber(byFile: [
                "m-mic.caf": [TranscriptSegment(start: 0, end: 4, text: "이번 스펙 정리했습니다")],
                "m-system.mov": [
                    TranscriptSegment(start: 5, end: 9, text: "네 확인했습니다"),
                    TranscriptSegment(start: 10, end: 14, text: "그럼 다음 주에 뵙겠습니다"),
                ],
            ]),
            diarizer: nil, probe: FakeProbe(systemHasSpeech: true))

        let result = try await pipeline.run(mixed: mixed, system: system, mic: mic)

        #expect(result.segments.map(\.speaker) == ["나", "상대", "상대"])
        #expect(result.diarizationNote?.contains("한 사람으로 묶었") == true)
    }
}

struct GapFillingTranscriber: Transcribing {
    var linesPerClip = 1
    var loops = false

    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 10, text: "1패스가 받아쓴 앞머리")]
    }

    func transcribe(audioURL: URL, hint: String?,
                    clips: [TranscriptCoverage.Gap]) async throws -> [TranscriptSegment] {
        clips.flatMap { clip -> [TranscriptSegment] in
            let span = clip.duration / Double(linesPerClip)
            return (0..<linesPerClip).map { index in
                TranscriptSegment(start: clip.start + span * Double(index),
                                  end: clip.start + span * Double(index + 1),
                                  text: loops ? "같은 말" : "되찾은 문장 \(index)")
            }
        }
    }
}

@Suite struct TranscriptRecoveryTests {
    @Test func dropsSegmentsOverlappingWhatPassOneAlreadyHas() {
        let existing = [TranscriptSegment(start: 0, end: 10, text: "이미 있는 말")]
        let recovered = [
            TranscriptSegment(start: 8, end: 12, text: "가장자리에 걸린 중복"),
            TranscriptSegment(start: 20, end: 25, text: "진짜 되찾은 말"),
        ]
        let kept = TranscriptRecovery.accept(recovered, into: existing,
                                             clips: [.init(start: 10, end: 30)])

        #expect(kept.map(\.text) == ["진짜 되찾은 말"])
    }

    @Test func dropsALoopedClipButKeepsTheOthers() {
        let looped = (0..<6).map {
            TranscriptSegment(start: 10 + Double($0), end: 11 + Double($0),
                              text: "스프레드 시트에 링크 남겨놨어요")
        }
        let sane = [TranscriptSegment(start: 40, end: 45, text: "멀쩡한 문장")]
        let kept = TranscriptRecovery.accept(looped + sane, into: [],
                                             clips: [.init(start: 10, end: 20),
                                                     .init(start: 35, end: 50)])

        #expect(kept.map(\.text) == ["멀쩡한 문장"])
    }

    @Test func doesNotCallThreeShortAcknowledgementsALoop() {
        let short = (0..<3).map {
            TranscriptSegment(start: 10 + Double($0), end: 11 + Double($0), text: "네.")
        }
        #expect(TranscriptRecovery.isLoop(short) == false)
    }
}

@Suite struct TranscriptRecoveryPipelineTests {
    @Test func secondPassFillsWhatTheFirstPassLeftEmpty() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: GapFillingTranscriber(),
            probe: FakeProbe(systemHasSpeech: false, trackDuration: 120))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.segments.count == 2)
        #expect(result.segments.last?.text == "되찾은 문장 0")
        #expect(result.coverage?.hasLoss == false, "채운 뒤에는 남은 갭이 없다")
        #expect(result.coverage?.recoveredSeconds ?? 0 > 100)
        #expect(result.diarizationNote?.contains("재전사로 채웠습니다") == true,
                "조용히 채우면 무엇이 1패스 결과인지 알 수 없다")
    }

    @Test func loopedSecondPassChangesNothing() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: GapFillingTranscriber(linesPerClip: 8, loops: true),
            probe: FakeProbe(systemHasSpeech: false, trackDuration: 120))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.segments.map(\.text) == ["1패스가 받아쓴 앞머리"])
        #expect(result.coverage?.recoveredSeconds == 0)
        #expect(result.coverage?.gaps == [.init(start: 10, end: 120)])
    }

    @Test func transcriberWithoutClipSupportKeepsPassOne() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: FakeTranscriber(),
            probe: FakeProbe(systemHasSpeech: false, trackDuration: 120))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.segments.count == 2)
        #expect(result.coverage?.gaps == [.init(start: 10, end: 120)])
        #expect(result.coverage?.recoveredSeconds == 0)
    }

    @Test func recoveredSegmentsGetTheSameSpeakerLabels() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: GapFillingTranscriber(),
            diarizer: FakeDiarizer(turnsByFile: [
                "m.m4a": [
                    TranscriptSegment(speaker: "S1", start: 0, end: 10, text: ""),
                    TranscriptSegment(speaker: "S2", start: 10, end: 120, text: ""),
                ],
            ]),
            probe: FakeProbe(systemHasSpeech: false, trackDuration: 120))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.segments.last?.speaker == "화자2")
    }
}

@Suite struct TranscriptGapRenderingTests {
    private let segments = [
        TranscriptSegment(speaker: "화자1", start: 0, end: 10, text: "앞머리"),
        TranscriptSegment(speaker: "화자2", start: 120, end: 130, text: "한참 뒤"),
    ]

    @Test func storedTranscriptKeepsItsShape() {
        let text = TranscriptMerger.plainText(segments)

        #expect(text == "[00:00] 화자1: 앞머리\n[02:00] 화자2: 한참 뒤")
        #expect(TranscriptSegment.parseLegacy(text).count == 2)
    }

    @Test func promptCopyShowsTheHoles() {
        let text = TranscriptMerger.plainText(segments, gaps: [.init(start: 10, end: 120)])

        #expect(text == """
        [00:00] 화자1: 앞머리
        [00:10] ⟨전사 없음 · 110초⟩
        [02:00] 화자2: 한참 뒤
        """)
    }

    @Test func keepsMinuteSecondsPastAnHour() {
        let long = [TranscriptSegment(start: 3776, end: 3780, text: "막바지")]
        #expect(TranscriptMerger.plainText(long).hasPrefix("[62:56]"))
    }
}

@Suite struct TranscriptCoverageTests {
    @Test func countsGapsAtHeadMiddleAndTail() {
        let segments = [
            TranscriptSegment(start: 60, end: 90, text: "여기서 시작합니다"),
            TranscriptSegment(start: 150, end: 180, text: "다시 이어집니다"),
        ]
        let coverage = TranscriptCoverage.measure(segments: segments, duration: 240)

        #expect(coverage?.gaps == [
            .init(start: 0, end: 60), .init(start: 90, end: 150), .init(start: 180, end: 240),
        ])
        #expect(coverage?.missingSeconds == 180)
        #expect(coverage?.note?.contains("3곳") == true)
    }

    @Test func ignoresShortPauses() {
        let segments = [
            TranscriptSegment(start: 0, end: 10, text: "한 마디"),
            TranscriptSegment(start: 18, end: 30, text: "숨 쉬고 다음 마디"),
        ]
        let coverage = TranscriptCoverage.measure(segments: segments, duration: 35)

        #expect(coverage?.hasLoss == false)
        #expect(coverage?.note == nil)
    }

    @Test func handlesOverlappingAndUnsortedSegments() {
        let segments = [
            TranscriptSegment(speaker: "나", start: 0, end: 30, text: "길게 말합니다"),
            TranscriptSegment(speaker: "상대1", start: 5, end: 12, text: "네"),
        ]
        let coverage = TranscriptCoverage.measure(segments: segments.reversed(), duration: 35)

        #expect(coverage?.gaps.isEmpty == true)
    }

    @Test func skipsMeasurementWithoutDuration() {
        let segments = [TranscriptSegment(start: 0, end: 5, text: "짧게")]
        #expect(TranscriptCoverage.measure(segments: segments, duration: 0) == nil)
    }

    @Test func pipelineMeasuresAfterTranscription() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: FakeTranscriber(),
            probe: FakeProbe(systemHasSpeech: false, trackDuration: 120))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.coverage?.gaps == [.init(start: 10, end: 120)])
        #expect(result.coverage?.missingRatio ?? 0 > 0.9)
    }

    @Test func pipelineLeavesCoverageEmptyWhenDurationUnknown() async throws {
        let pipeline = LocalTranscriptionPipeline(
            transcriber: FakeTranscriber(), probe: FakeProbe(systemHasSpeech: false))
        let result = try await pipeline.run(mixed: URL(fileURLWithPath: "/tmp/m.m4a"),
                                            system: nil, mic: nil)

        #expect(result.coverage == nil)
    }

    @Test func documentListsMissingRanges() {
        let meeting = Meeting(
            title: "위클리", status: .done,
            segments: [TranscriptSegment(start: 0, end: 10, text: "시작")],
            coverage: TranscriptCoverage(duration: 120, gaps: [.init(start: 10, end: 120)]),
            summary: "## 핵심 내용")
        let markdown = MeetingDocument.markdown(meeting)

        #expect(markdown.contains("전사 누락:"))
        #expect(markdown.contains("00:10 ~ 02:00"))
    }
}

@Suite struct MeetingMigrationTests {
    @Test func legacyRowWithoutNewKeysStillDecodes() throws {
        let json = """
        {"id":"m1","title":"7월 킥오프","scheduledAt":770000000,"status":"done",
         "transcript":"[00:03] S1: 시작합시다","summary":"## 핵심 내용","micAudioPath":"/tmp/a.caf"}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))

        #expect(meeting.title == "7월 킥오프")
        #expect(meeting.segments.isEmpty)
        #expect(meeting.speakerNames.isEmpty)
        #expect(meeting.diarizationNote == nil)
        #expect(meeting.origin == nil)
        #expect(meeting.coverage == nil)
        #expect(meeting.pausedSeconds == 0)
    }

    @Test func roundTripKeepsNewFields() throws {
        let meeting = Meeting(
            title: "위클리", pausedSeconds: 90, status: .done,
            segments: [TranscriptSegment(speaker: "상대1", start: 0, end: 3, text: "안녕하세요")],
            speakerNames: ["상대1": "김OO"], diarizationNote: "건너뜀",
            origin: Meeting.Origin(appName: "Google Chrome",
                                   bundleID: "com.google.Chrome",
                                   windowTitle: "위클리 - Google Meet"))
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)

        #expect(decoded.segments == meeting.segments)
        #expect(decoded.speakerNames == ["상대1": "김OO"])
        #expect(decoded.origin?.bundleID == "com.google.Chrome")
        #expect(decoded.pausedSeconds == 90)
    }

    @Test func parsesLegacyTranscriptBackIntoSegments() {
        let segments = TranscriptSegment.parseLegacy("""
        [00:03] S1: 시작합시다
        [01:05] S2: 네 좋습니다
        [1:02:07] S1: 마무리하죠
        형식이 없는 줄
        """)

        #expect(segments.count == 4)
        #expect(segments[0].speaker == "S1")
        #expect(segments[0].start == 3)
        #expect(segments[1].start == 65)
        #expect(segments[2].start == 3727, "hh:mm:ss도 초로 환산한다")
        #expect(segments[3].isSeekable == false, "형식 미상 줄은 내용만 남기고 재생 대상에서 뺀다")
        #expect(segments[3].text == "형식이 없는 줄")
    }

    @Test func displaySegmentsPrefersStoredSegments() {
        let stored = Meeting(title: "a",
                             segments: [TranscriptSegment(start: 0, end: 1, text: "새 경로")],
                             transcript: "[00:00] 옛 경로")
        #expect(stored.displaySegments.map(\.text) == ["새 경로"])

        let legacy = Meeting(title: "a", transcript: "[00:00] 옛 경로")
        #expect(legacy.displaySegments.map(\.text) == ["옛 경로"])
    }
}

@Suite struct SpeakerNamingTests {
    @Test func plainTextUsesAssignedNames() {
        let segments = [
            TranscriptSegment(speaker: "상대1", start: 0, end: 3, text: "안녕하세요"),
            TranscriptSegment(speaker: "나", start: 3, end: 6, text: "네 반갑습니다"),
        ]
        let text = TranscriptMerger.plainText(segments, names: ["상대1": "김OO"])

        #expect(text.contains("[00:00] 김OO: 안녕하세요"))
        #expect(text.contains("[00:03] 나: 네 반갑습니다"), "이름을 안 붙인 라벨은 그대로 쓴다")
    }

    @Test func renameSpeakerRewritesTranscript() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let meeting = Meeting(
            title: "위클리", status: .done,
            segments: [TranscriptSegment(speaker: "상대1", start: 0, end: 3, text: "안녕하세요")],
            transcript: "[00:00] 상대1: 안녕하세요")
        try await store.upsert(.meeting, meeting)

        try await center.renameSpeaker(meetingID: meeting.id, label: "상대1", name: "김OO")

        let named = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(named?.speakerNames["상대1"] == "김OO")
        #expect(named?.transcript == "[00:00] 김OO: 안녕하세요")
        #expect(named?.displayName(for: "상대1") == "김OO")

        try await center.renameSpeaker(meetingID: meeting.id, label: "상대1", name: "  ")
        let cleared = await store.fetch(.meeting, id: meeting.id, as: Meeting.self)
        #expect(cleared?.speakerNames["상대1"] == nil, "빈 이름은 라벨로 되돌린다")
        #expect(cleared?.transcript == "[00:00] 상대1: 안녕하세요")
    }

    @Test func concurrentRenamesKeepMappingAndTranscriptConsistent() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let center = MeetingCenter(store: store, recorder: FakeRecorder(),
                                   transcription: nil, analyzer: nil, mixer: PassthroughMixer())
        let meeting = Meeting(
            title: "위클리", status: .done,
            segments: [
                TranscriptSegment(speaker: "상대1", start: 0, end: 3, text: "안녕하세요"),
                TranscriptSegment(speaker: "상대2", start: 3, end: 6, text: "네"),
            ])
        try await store.upsert(.meeting, meeting)

        async let first: Void = center.renameSpeaker(meetingID: meeting.id,
                                                     label: "상대1", name: "김OO")
        async let second: Void = center.renameSpeaker(meetingID: meeting.id,
                                                      label: "상대2", name: "박OO")
        _ = try await (first, second)

        let stored = try #require(await store.fetch(.meeting, id: meeting.id, as: Meeting.self))
        #expect(stored.speakerNames == ["상대1": "김OO", "상대2": "박OO"])
        #expect(stored.transcript.contains("김OO") && stored.transcript.contains("박OO"),
                "한쪽 이름 변경이 다른 쪽 전사 재생성에 덮였다")
    }
}

final class FakeCallSignals: CallSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _onMic: String?
    private var _window: ConferencingWindow?

    func set(onMic: String?, window: ConferencingWindow?) {
        lock.withLock {
            _onMic = onMic
            _window = window
        }
    }

    func conferencingAppOnMicrophone() async -> String? { lock.withLock { _onMic } }
    func conferencingWindow(bundleID: String) async -> ConferencingWindow? { lock.withLock { _window } }
}

final class DetectionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CallDetection?] = []

    func append(_ value: CallDetection?) { lock.withLock { stored.append(value) } }
    var values: [CallDetection?] { lock.withLock { stored } }
}

@Suite struct CallDetectorTests {
    private let meet = CallDetection(appName: "Google Chrome",
                                     bundleID: "com.google.Chrome",
                                     windowTitle: "팀 위클리 - Google Meet")
    private let meetWindow = ConferencingWindow(appName: "Google Chrome",
                                                title: "팀 위클리 - Google Meet")

    @Test func risesOnlyAfterDebounce() async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        signals.set(onMic: "com.google.Chrome", window: meetWindow)
        let start = Date()
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(1))
        #expect(received.values.isEmpty, "처음 잡힌 순간에는 아직 통화로 보지 않는다")

        await detector.tick(now: start.addingTimeInterval(1.5))
        await detector.stop()
        _ = await collector.result
        #expect(received.values.compactMap { $0 } == [meet])
    }

    @Test func micAloneIsNotACall() async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        signals.set(onMic: nil, window: meetWindow)
        let start = Date()
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(30))

        await detector.stop()
        _ = await collector.result
        #expect(received.values.isEmpty)
    }

    @Test func detectsCallWithoutAnyConferencingWindow() async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        signals.set(onMic: "com.tinyspeck.slackmacgap", window: nil)
        let start = Date()
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(2))
        await detector.stop()
        _ = await collector.result

        let detected = received.values.compactMap { $0 }
        #expect(detected.count == 1, "창 제목이 없어도 마이크를 쥔 회의 앱은 통화다")
        #expect(detected.first?.suggestedTitle == "Slack")
    }

    @Test func keepsFirstTitleWhileCallContinues() async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        signals.set(onMic: "com.google.Chrome", window: meetWindow)
        let start = Date()
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(2))
        signals.set(onMic: "com.google.Chrome",
                    window: ConferencingWindow(appName: "Google Chrome", title: "다른 탭"))
        await detector.tick(now: start.addingTimeInterval(4))
        await detector.tick(now: start.addingTimeInterval(6))
        await detector.stop()
        _ = await collector.result

        #expect(received.values.count == 1, "같은 통화는 한 번만 발행한다")
        #expect(received.values.first ?? nil == meet, "제목은 처음 잡은 값으로 고정된다")
    }

    @Test(arguments: [(10.0, 1), (30.0, 2)])
    func fallsOnlyAfterLongerDebounce(gap: TimeInterval, expected: Int) async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        let start = Date()
        signals.set(onMic: "com.google.Chrome", window: meetWindow)
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(6))

        signals.set(onMic: nil, window: nil)
        await detector.tick(now: start.addingTimeInterval(7))
        await detector.tick(now: start.addingTimeInterval(7 + gap))
        await detector.stop()
        _ = await collector.result

        #expect(received.values.count == expected,
                "\(Int(gap))초 공백 — 15초를 넘겨야만 통화를 접는다")
        if expected == 2 {
            #expect(received.values.last ?? nil == nil, "종료는 nil로 알린다")
        }
    }

    @Test func suppressedWhileRecording() async throws {
        let signals = FakeCallSignals()
        let detector = CallDetector(signals: signals, pollInterval: 3600)
        let received = DetectionCollector()
        let stream = await detector.detections()
        let collector = Task { for await value in stream { received.append(value) } }

        await detector.setSuppressed(true)
        signals.set(onMic: "com.google.Chrome", window: meetWindow)
        let start = Date()
        await detector.tick(now: start)
        await detector.tick(now: start.addingTimeInterval(60))

        await detector.stop()
        _ = await collector.result
        #expect(received.values.isEmpty)
    }

    @Test(arguments: [
        ("팀 위클리 - Google Meet - Google Chrome", "Google Chrome", "팀 위클리 - Google Meet"),
        ("Meet - abc-defg-hij \u{1F50A}", "Google Chrome", "Meet - abc-defg-hij"),
        ("* product-검색(채널) - Acme Workspace - Slack [기본] \u{1F3E0}\u{1F50A}",
         "Slack", "product-검색(채널) - Acme Workspace"),
    ])
    func cleansAppSuffixFromWindowTitle(title: String, appName: String, expected: String) {
        #expect(SystemCallSignals.cleanTitle(title, appName: appName) == expected)
    }

    @Test func suggestedTitleFallsBackToAppName() {
        let bare = CallDetection(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 windowTitle: "")
        #expect(bare.suggestedTitle == "Slack")
        #expect(meet.suggestedTitle == "팀 위클리 - Google Meet")
    }
}

@Suite struct AudioProbeTests {
    @Test func joinsBreathGapsThenDropsShortNoise() {
        let turns = AudioProbe.tidy([
            TranscriptSegment(start: 0, end: 0.4, text: ""),
            TranscriptSegment(start: 0.9, end: 1.6, text: ""),
            TranscriptSegment(start: 10, end: 10.2, text: ""),
        ])

        #expect(turns.count == 1)
        #expect(turns[0].start == 0 && turns[0].end == 1.6, "0.8초 이내 간격은 한 발화로 잇는다")
    }

    @Test func readsToneAsSpeechAndSilenceAsNone() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tone = dir.appendingPathComponent("tone.caf")
        let silence = dir.appendingPathComponent("silence.caf")
        try writeSignal(to: tone, seconds: 5) { index, sampleRate in
            Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate)) * 0.5
        }
        try writeSignal(to: silence, seconds: 5) { _, _ in 0 }

        #expect(await AudioProbe.hasSpeech(url: tone))
        #expect(await AudioProbe.hasSpeech(url: silence) == false)
        #expect(await AudioProbe.hasSpeech(url: nil) == false)

        let turns = await AudioProbe.voicedTurns(url: tone, label: "나")
        #expect(turns.first?.speaker == "나")
        #expect((turns.first?.end ?? 0) > 4, "연속 톤은 한 구간으로 이어진다")
    }

    private func writeSignal(to url: URL, seconds: Double,
                             sample: (Int, Double) -> Float) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                       AVSampleRateKey: sampleRate,
                       AVNumberOfChannelsKey: 1,
                       AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true,
                       AVLinearPCMIsNonInterleaved: false])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = sample(index, sampleRate)
        }
        try file.write(from: buffer)
    }
}

@Suite struct MeetingListCacheTests {
    private func makeCenter() throws -> (MeetingCenter, SQLiteMeetingStore) {
        let store = try SQLiteMeetingStore.inMemory()
        return (MeetingCenter(store: store, recorder: FakeRecorder(),
                              transcription: nil, analyzer: nil, mixer: PassthroughMixer()),
                store)
    }

    @Test func unchangedRowsReuseTheSameBuffer() async throws {
        let (center, _) = try makeCenter()
        _ = try await center.startAdhocRecording(title: "첫 미팅")
        _ = try await center.finishRecording()

        let first = await center.meetings()
        let second = await center.meetings()

        let firstBuffer = first.withUnsafeBufferPointer { $0.baseAddress }
        let secondBuffer = second.withUnsafeBufferPointer { $0.baseAddress }
        #expect(firstBuffer == secondBuffer)
    }

    @Test func changedRowIsRefetched() async throws {
        let (center, _) = try makeCenter()
        let meeting = try await center.startAdhocRecording(title: "옛 제목")
        _ = try await center.finishRecording()
        _ = await center.meetings()

        try await center.renameMeeting(id: meeting.id, title: "새 제목")

        let reloaded = await center.meetings()
        #expect(reloaded.first { $0.id == meeting.id }?.title == "새 제목")
    }

    @Test func concurrentReadsNeverDivergeFromStore() async throws {
        let (center, store) = try makeCenter()
        var ids: [String] = []
        for i in 0..<13 {
            let m = Meeting(title: "미팅 \(i)",
                            scheduledAt: Date(timeIntervalSince1970: 1_786_000_000 + Double(i)),
                            status: .summarizing,
                            transcript: String(repeating: "가", count: 2000))
            ids.append(m.id)
            try await store.upsert(.meeting, m)
        }
        _ = await center.meetings()

        for round in 0..<40 {
            _ = try await store.mutate(.meeting, id: ids[round % ids.count], as: Meeting.self) {
                $0.status = round % 2 == 0 ? .done : .summarizing
                return true
            }
            _ = try await store.mutate(.meeting, id: ids[(round + 5) % ids.count],
                                       as: Meeting.self) {
                $0.summary = "라운드 \(round)"
                return true
            }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<6 { group.addTask { _ = await center.meetings() } }
            }
            let (rival, _) = (MeetingCenter(store: store, recorder: FakeRecorder(),
                                            transcription: nil, analyzer: nil,
                                            mixer: PassthroughMixer()), store)
            let cached = await center.meetings()
            let truth = await rival.meetings()
            #expect(cached == truth, "라운드 \(round)에서 캐시가 저장소와 갈라졌다")
            if cached != truth { return }
        }
    }

    @Test func completedMeetingNeverStaysInProgress() async throws {
        let (center, store) = try makeCenter()
        let meeting = try await center.startAdhocRecording(title: "재요약 대상")
        _ = try await center.finishRecording()
        _ = try await store.mutate(.meeting, id: meeting.id, as: Meeting.self) {
            $0.status = .summarizing
            return true
        }
        #expect(await center.meetings().first { $0.id == meeting.id }?.status == .summarizing)

        _ = try await store.mutate(.meeting, id: meeting.id, as: Meeting.self) {
            $0.status = .done
            return true
        }
        #expect(await center.meetings().first { $0.id == meeting.id }?.status == .done,
                "완료된 미팅이 '정리 중'으로 남는다")
    }

    @Test func addedAndDeletedRowsAreReflected() async throws {
        let (center, _) = try makeCenter()
        let first = try await center.startAdhocRecording(title: "하나")
        _ = try await center.finishRecording()
        #expect(await center.meetings().count == 1)

        let second = try await center.startAdhocRecording(title: "둘")
        _ = try await center.finishRecording()
        #expect(await center.meetings().count == 2)

        try await center.deleteMeeting(id: first.id)
        let remaining = await center.meetings()
        #expect(remaining.map(\.id) == [second.id])
    }

    @Test func backfillStoresSegmentsForLegacyMeetings() async throws {
        let (center, store) = try makeCenter()
        let legacy = Meeting(title: "구 미팅", status: .done,
                             transcript: "[00:05] 나: 안녕하세요\n[00:12] 상대1: 반갑습니다")
        try await store.upsert(.meeting, legacy)

        await center.backfillTranscriptSegments()

        let stored = try #require(await store.fetch(.meeting, id: legacy.id, as: Meeting.self))
        #expect(stored.segments.count == 2)
        #expect(stored.segments.first?.speaker == "나")
        #expect(stored.segments.first?.start == 5)
        #expect(stored.transcript == legacy.transcript, "전사 문자열은 건드리지 않는다")
    }

    @Test func deleteRemovesWhisperIntermediates() async throws {
        let (center, store) = try makeCenter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mixed = dir.appendingPathComponent("m-system.mixed.m4a")
        let wav = dir.appendingPathComponent("m-system.mixed.16k.wav")
        let json = dir.appendingPathComponent("m-system.mixed.16k.json")
        for url in [mixed, wav, json] { try Data("x".utf8).write(to: url) }
        let meeting = Meeting(title: "정리 대상", status: .done, mixedAudioPath: mixed.path)
        try await store.upsert(.meeting, meeting)

        try await center.deleteMeeting(id: meeting.id)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: mixed.path))
        #expect(!fm.fileExists(atPath: wav.path), "중간 wav가 남으면 미팅을 지워도 용량이 준다")
        #expect(!fm.fileExists(atPath: json.path))
    }
}
