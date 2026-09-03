import Foundation

public actor MeetingCenter {
    private let store: any MeetingStoring
    private let recorder: MeetingRecording
    private let transcription: LocalTranscriptionPipeline?
    private let mixer: AudioMixing
    private let analyzer: (any MeetingSummarizing)?
    private let notifier: any MeetingNotifying
    private let vault: MeetingVaultExporter?
    private let live: LiveTranscribing?
    private let glossary: String
    private let summaryLanguage: String
    private let hostDisplayName: String
    private var liveSaver: Task<Void, Never>?
    private var activeMeetingID: String?
    private var cachedStamps: [String: String] = [:]
    private var cachedMeetings: [Meeting] = []
    private var cacheTicket = 0
    private var committedTicket = 0
    private var isFinishing = false

    public init(store: any MeetingStoring, recorder: MeetingRecording,
                transcription: LocalTranscriptionPipeline?, analyzer: (any MeetingSummarizing)?,
                mixer: AudioMixing = AVFoundationAudioMixer(),
                notifier: any MeetingNotifying = SilentMeetingNotifier(),
                vault: MeetingVaultExporter? = nil,
                live: LiveTranscribing? = nil,
                glossary: String = "",
                summaryLanguage: String = "ko",
                hostDisplayName: String = "meeting") {
        self.store = store
        self.recorder = recorder
        self.transcription = transcription
        self.mixer = mixer
        self.analyzer = analyzer
        self.notifier = notifier
        self.vault = vault
        self.live = live
        self.glossary = glossary
        self.summaryLanguage = summaryLanguage
        self.hostDisplayName = hostDisplayName
    }

    public enum RecordingError: Error {
        case alreadyRecording
    }

    static let summaryFailurePrefix = "요약 실패"

    public func startRecording(meetingID: String) async throws {
        guard activeMeetingID == nil else { throw RecordingError.alreadyRecording }
        activeMeetingID = meetingID
        guard await store.meeting(id: meetingID) != nil else {
            activeMeetingID = nil
            return
        }
        do {
            try await recorder.start(meetingID: meetingID)
        } catch {
            activeMeetingID = nil
            _ = try await update(meetingID) {
                $0.status = .failed
                $0.failureReason = "녹음 시작 실패: \(error.localizedDescription)\n"
                    + "마이크 권한이 필요합니다. "
                    + "시스템 설정 > 개인정보 보호 및 보안에서 \(hostDisplayName)를 허용해 주십시오."
            }
            throw error
        }
        guard let meeting = try await update(meetingID, {
            $0.status = .recording
            $0.startedAt = Date()
        }) else {
            activeMeetingID = nil
            return
        }
        await live?.start()
        startLiveSaver(meetingID: meetingID)
        await notifier.notice(message: "녹음 시작: \(meeting.title)")
    }

    @discardableResult
    public func startAdhocRecording(title: String,
                                    origin: Meeting.Origin? = nil) async throws -> Meeting {
        let meeting = Meeting(title: title, scheduledAt: Date(), origin: origin)
        try await store.upsertMeeting(meeting)
        do {
            try await startRecording(meetingID: meeting.id)
        } catch RecordingError.alreadyRecording {
            try? await store.deleteMeeting(id: meeting.id)
            throw RecordingError.alreadyRecording
        }
        return await store.meeting(id: meeting.id) ?? meeting
    }

    public struct FinishedRecording: Sendable {
        public let meeting: Meeting
        let audio: RecordedAudio
        let resumeFromSummary: Bool

        init(meeting: Meeting, audio: RecordedAudio, resumeFromSummary: Bool = false) {
            self.meeting = meeting
            self.audio = audio
            self.resumeFromSummary = resumeFromSummary
        }
    }

    public func finishRecording() async throws -> FinishedRecording? {
        guard let meetingID = activeMeetingID, !isFinishing else { return nil }
        isFinishing = true
        let audio: RecordedAudio
        do {
            audio = try await recorder.stop()
        } catch {
            isFinishing = false
            activeMeetingID = nil
            liveSaver?.cancel()
            _ = await live?.stop()
            _ = try await markFailed(meetingID,
                                     reason: "녹음 종료 실패: \(error.localizedDescription)")
            throw error
        }
        liveSaver?.cancel()
        liveSaver = nil
        let draft = await live?.stop() ?? []
        let meeting = try await update(meetingID) {
            $0.endedAt = Date()
            $0.systemAudioPath = audio.systemAudioURL?.path
            $0.micAudioPath = audio.micURL?.path
            $0.status = .transcribing
            if !draft.isEmpty {
                $0.segments = draft
                $0.transcript = TranscriptMerger.plainText(draft, names: $0.speakerNames)
            }
        }
        isFinishing = false
        activeMeetingID = nil
        guard let meeting else { return nil }
        return FinishedRecording(meeting: meeting, audio: audio)
    }

    @discardableResult
    public func processRecording(_ finished: FinishedRecording) async throws -> Meeting? {
        try await processRecordedMeeting(meeting: finished.meeting, audio: finished.audio,
                                         resumeFromSummary: finished.resumeFromSummary)
    }

    @discardableResult
    public func stopRecording() async throws -> Meeting? {
        guard let finished = try await finishRecording() else { return nil }
        return try await processRecording(finished)
    }

    public func prepareReprocess(meetingID: String,
                                 summaryOnly override: Bool? = nil) async throws
    -> FinishedRecording? {
        guard let meeting = await store.meeting(id: meetingID),
              meeting.status == .failed || meeting.status == .done else { return nil }
        let summaryOnly = override ?? meeting.reprocessesSummaryOnly
        let fm = FileManager.default
        let systemURL = meeting.systemAudioPath.map { URL(fileURLWithPath: $0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        let micURL = meeting.micAudioPath.map { URL(fileURLWithPath: $0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        guard systemURL != nil || micURL != nil else { return nil }
        let entry = meeting.status
        guard let updated = try await store.mutateMeeting(id: meetingID, {
            guard $0.status == entry else { return false }
            $0.status = summaryOnly && entry == .done ? .summarizing : .transcribing
            $0.failureReason = nil
            return true
        }) else { return nil }
        return FinishedRecording(
            meeting: updated,
            audio: RecordedAudio(systemAudioURL: systemURL, micURL: micURL),
            resumeFromSummary: summaryOnly)
    }

    private func startLiveSaver(meetingID: String) {
        guard let live else { return }
        liveSaver?.cancel()
        liveSaver = Task { [weak self] in
            var savedCount = 0
            var savedAt = Date.distantPast
            for await update in live.updates() {
                if Task.isCancelled { return }
                guard update.confirmed.count > savedCount,
                      Date().timeIntervalSince(savedAt) >= 15 else { continue }
                savedCount = update.confirmed.count
                savedAt = Date()
                await self?.saveLiveDraft(meetingID: meetingID, segments: update.confirmed)
            }
        }
    }

    private func saveLiveDraft(meetingID: String, segments: [TranscriptSegment]) async {
        _ = try? await store.mutateMeeting(id: meetingID) { meeting in
            guard meeting.status == .recording else { return false }
            meeting.segments = segments
            meeting.transcript = TranscriptMerger.plainText(segments, names: meeting.speakerNames)
            return true
        }
    }

    private func processRecordedMeeting(meeting input: Meeting, audio: RecordedAudio,
                                        resumeFromSummary: Bool = false) async throws -> Meeting? {
        let meetingID = input.id
        var meeting: Meeting

        if !(resumeFromSummary && Self.hasReusableTranscript(input)) {
            var audioURL: URL?
            do {
                audioURL = try await mixer.mixForTranscription(
                    system: audio.systemAudioURL, mic: audio.micURL,
                    micStartOffset: audio.micStartOffset)
            } catch {
                if transcription != nil {
                    return try await markFailed(meetingID, reason: "전사 실패: \(error)",
                                                notice: "전사 실패")
                }
            }

            var segments: [TranscriptSegment] = []
            var diarizationNote: String?
            var coverage: TranscriptCoverage?
            if let transcription, let audioURL {
                do {
                    let result = try await transcription.run(
                        mixed: audioURL, system: audio.systemAudioURL, mic: audio.micURL,
                        micStartOffset: audio.micStartOffset,
                        hint: input.transcriptionHint)
                    segments = result.segments
                    diarizationNote = result.diarizationNote
                    coverage = result.coverage
                } catch {
                    return try await markFailed(meetingID, reason: "전사 실패: \(error)",
                                                notice: "전사 실패")
                }
            }

            let mixedPath = audioURL?.path
            let transcribed = segments
            let note = diarizationNote
            let measured = coverage
            guard let updated = try await update(meetingID, {
                $0.mixedAudioPath = mixedPath
                $0.segments = transcribed
                $0.diarizationNote = note
                $0.coverage = measured
                $0.transcript = TranscriptMerger.plainText(transcribed, names: $0.speakerNames)
                $0.status = .summarizing
            }) else { return nil }
            meeting = updated
        } else {
            guard let updated = try await update(meetingID, { $0.status = .summarizing })
            else { return nil }
            meeting = updated
        }

        var finalSummary: String?
        var suggestedSpeakers: [String: String] = [:]
        if let analyzer, !meeting.transcript.isEmpty {
            let prompt = MeetingSummaryPrompt.build(
                title: meeting.title,
                transcript: TranscriptMerger.plainText(meeting.displaySegments,
                                                       names: meeting.speakerNames,
                                                       gaps: meeting.coverage?.gaps ?? []),
                glossary: glossary, speakerNames: meeting.speakerNames,
                coverage: meeting.coverage, language: summaryLanguage)
            do {
                let result = try await analyzer.summarize(
                    prompt: prompt, title: "미팅 요약: \(meeting.title)")
                let produced = result.summary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                suggestedSpeakers = result.speakers
                guard !produced.isEmpty else {
                    return try await markFailed(
                        meetingID, reason: "\(Self.summaryFailurePrefix): 요약이 비어 있습니다.",
                        notice: Self.summaryFailurePrefix)
                }
                finalSummary = produced
            } catch {
                return try await markFailed(
                    meetingID,
                    reason: "\(Self.summaryFailurePrefix): \(error.localizedDescription)",
                    notice: Self.summaryFailurePrefix)
            }
        }
        let summary = finalSummary
        let suggestions = suggestedSpeakers
        guard let done = try await update(meetingID, { meeting in
            if let summary { meeting.summary = summary }
            meeting.speakerNameSuggestions = suggestions.filter { label, name in
                meeting.speakerNames[label] == nil && !name.isEmpty && name != label
            }
            meeting.status = .done
        }) else { return nil }
        let exported = await exportToVault(done)
        await notifier.notice(
            message: "\(done.title) 정리 완료 — 요약과 전사가 준비되었습니다.")
        return exported ?? done
    }

    private func exportToVault(_ meeting: Meeting) async -> Meeting? {
        guard let vault else { return nil }
        do {
            guard let written = try vault.export(meeting) else { return nil }
            let updated = try await update(meeting.id) {
                $0.vaultNotePath = written.notePath
                $0.vaultTranscriptPath = written.transcriptPath
            }
            for warning in written.warnings {
                await notifier.notice(message: "\(meeting.title) \(warning)")
            }
            if case .failed(let reason) = await vault.refreshIndex() {
                await notifier.notice(message: "위키 인덱스 갱신 실패 — \(reason)")
            }
            return updated
        } catch {
            await notifier.notice(
                message: "\(meeting.title) 위키 저장 실패 — \(error.localizedDescription)")
            return nil
        }
    }

    private func refreshVaultExport(_ meeting: Meeting) async {
        guard meeting.vaultNotePath != nil else { return }
        _ = await exportToVault(meeting)
    }

    private static func hasReusableTranscript(_ meeting: Meeting) -> Bool {
        guard !meeting.segments.isEmpty || !meeting.transcript.isEmpty,
              let mixed = meeting.mixedAudioPath,
              FileManager.default.fileExists(atPath: mixed) else { return false }
        return true
    }

    private func update(_ id: String,
                        _ apply: @Sendable (inout Meeting) -> Void) async throws -> Meeting? {
        try await store.mutateMeeting(id: id) {
            apply(&$0)
            return true
        }
    }

    private func markFailed(_ id: String, reason: String,
                            notice: String = "정리 실패") async throws -> Meeting? {
        guard let meeting = try await update(id, {
            $0.status = .failed
            $0.failureReason = reason
        }) else { return nil }
        await notifier.notice(message: "\(meeting.title) \(notice)")
        return meeting
    }

    public func renameMeeting(id: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let updated = try await update(id, { $0.title = trimmed }) else { return }
        await refreshVaultExport(updated)
    }

    public func renameSpeaker(meetingID: String, label: String, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try await update(meetingID) { meeting in
            if trimmed.isEmpty {
                meeting.speakerNames.removeValue(forKey: label)
            } else {
                meeting.speakerNames[label] = trimmed
            }
            meeting.speakerNameSuggestions.removeValue(forKey: label)
            meeting.transcript = TranscriptMerger.plainText(meeting.displaySegments,
                                                            names: meeting.speakerNames)
        }
        guard let updated else { return }
        await refreshVaultExport(updated)
    }

    public func applySpeakerSuggestions(meetingID: String) async throws {
        let updated = try await update(meetingID) { meeting in
            for (label, name) in meeting.speakerNameSuggestions {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                meeting.speakerNames[label] = trimmed
            }
            meeting.speakerNameSuggestions = [:]
            meeting.transcript = TranscriptMerger.plainText(meeting.displaySegments,
                                                            names: meeting.speakerNames)
        }
        guard let updated else { return }
        await refreshVaultExport(updated)
    }

    public func dismissSpeakerSuggestions(meetingID: String) async throws {
        _ = try await update(meetingID) { $0.speakerNameSuggestions = [:] }
    }

    public func deleteMeeting(id: String) async throws {
        guard id != activeMeetingID,
              let meeting = await store.meeting(id: id) else { return }
        var paths = [meeting.systemAudioPath, meeting.micAudioPath, meeting.mixedAudioPath]
            .compactMap { $0 }
        if let system = meeting.systemAudioPath {
            paths.append(URL(fileURLWithPath: system)
                .deletingPathExtension().appendingPathExtension("mixed.m4a").path)
        }
        paths += paths.flatMap { path -> [String] in
            let base = URL(fileURLWithPath: path).deletingPathExtension()
            return [base.appendingPathExtension("16k.wav").path,
                    base.appendingPathExtension("16k.json").path]
        }
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        vault?.remove(notePath: meeting.vaultNotePath,
                      transcriptPath: meeting.vaultTranscriptPath)
        try await store.deleteMeeting(id: id)
    }

    public func recoverInterruptedMeetings() async {
        guard activeMeetingID == nil else { return }
        let interrupted: Set<Meeting.Status> = [.recording, .transcribing, .summarizing]
        for meeting in await store.allMeetings()
        where interrupted.contains(meeting.status) {
            _ = try? await update(meeting.id) {
                $0.status = .failed
                $0.failureReason = "앱이 종료되어 녹음·정리가 중단되었습니다."
                    + " 녹음 파일이 남아 있으면 재생할 수 있습니다."
            }
        }
    }

    public func backfillTranscriptSegments() async {
        for meeting in await store.allMeetings()
        where meeting.segments.isEmpty && !meeting.transcript.isEmpty {
            let parsed = TranscriptSegment.parseLegacy(meeting.transcript)
            guard !parsed.isEmpty else { continue }
            _ = try? await update(meeting.id) { $0.segments = parsed }
        }
    }

    public func meetings() async -> [Meeting] {
        let stamps = await store.meetingStamps()
        guard stamps != cachedStamps else { return cachedMeetings }
        let base = cachedStamps
        let cached = Dictionary(uniqueKeysWithValues: cachedMeetings.map { ($0.id, $0) })
        cacheTicket += 1
        let ticket = cacheTicket
        var fresh: [Meeting] = []
        for (id, stamp) in stamps {
            if base[id] == stamp, let hit = cached[id] {
                fresh.append(hit)
            } else if let row = await store.meeting(id: id) {
                fresh.append(row)
            }
        }
        guard ticket > committedTicket else { return cachedMeetings }
        committedTicket = ticket
        cachedStamps = stamps
        cachedMeetings = fresh.sorted { $0.scheduledAt > $1.scheduledAt }
        return cachedMeetings
    }

    public var isRecording: Bool {
        activeMeetingID != nil
    }
}
