import Foundation

public struct SherpaDiarizer: Diarizing {
    public let scriptPath: String
    public let supportRoot: URL
    private let runner: ProcessRunning

    public init(scriptPath: String, supportRoot: URL, runner: ProcessRunning = ShellProcessRunner()) {
        self.scriptPath = scriptPath
        self.supportRoot = supportRoot
        self.runner = runner
    }

    public func diarize(audioURL: URL) async throws -> [TranscriptSegment] {
        let result = try await runner.run(
            "python3", arguments: [(scriptPath as NSString).expandingTildeInPath, audioURL.path],
            currentDirectory: nil,
            environment: ["MEETING_DIARIZATION_ROOT": supportRoot.path], timeout: 3600)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry -> TranscriptSegment? in
            guard let speaker = entry["speaker"] as? String,
                  let start = entry["start"] as? Double,
                  let end = entry["end"] as? Double else { return nil }
            return TranscriptSegment(speaker: speaker, start: start, end: end, text: "")
        }
    }
}

public enum TranscriptRecovery {
    static let loopRatio = 0.5
    static let loopMinimumLines = 4

    static let overlapTolerance: TimeInterval = 0.5

    public static func accept(_ recovered: [TranscriptSegment],
                              into existing: [TranscriptSegment],
                              clips: [TranscriptCoverage.Gap]) -> [TranscriptSegment] {
        var grouped: [Int: [TranscriptSegment]] = [:]
        for segment in recovered {
            let middle = (segment.start + segment.end) / 2
            let index = clips.firstIndex { $0.start <= middle && middle <= $0.end } ?? -1
            grouped[index, default: []].append(segment)
        }
        let surviving = grouped.values.filter { !isLoop($0) }.flatMap { $0 }

        return surviving
            .filter { candidate in
                !existing.contains { overlaps(candidate, $0) }
            }
            .sorted { $0.start < $1.start }
    }

    static func isLoop(_ segments: [TranscriptSegment]) -> Bool {
        guard segments.count >= loopMinimumLines else { return false }
        var counts: [String: Int] = [:]
        for segment in segments {
            let key = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            counts[key, default: 0] += 1
        }
        guard let top = counts.values.max() else { return false }
        return Double(top) / Double(segments.count) > loopRatio
    }

    private static func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        min(lhs.end, rhs.end) - max(lhs.start, rhs.start) > overlapTolerance
    }
}

public struct LocalTranscriptionPipeline: Sendable {
    public let transcriber: Transcribing
    public let diarizer: Diarizing?
    public let probe: TrackProbing
    public let glossary: String

    public init(transcriber: Transcribing, diarizer: Diarizing? = nil,
                probe: TrackProbing = SignalTrackProbe(), glossary: String = "") {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.probe = probe
        self.glossary = glossary
    }

    public struct Result: Sendable {
        public let segments: [TranscriptSegment]
        public let diarizationNote: String?
        public let coverage: TranscriptCoverage?

        public init(segments: [TranscriptSegment], diarizationNote: String?,
                    coverage: TranscriptCoverage? = nil) {
            self.segments = segments
            self.diarizationNote = diarizationNote
            self.coverage = coverage
        }
    }

    public func run(mixed: URL, system: URL?, mic: URL?,
                    micStartOffset: TimeInterval = 0,
                    hint: String? = nil) async throws -> Result {
        let online = await probe.hasSpeech(url: system)
        var notes: [String] = []
        let context = decodingHint(hint)
        let duration = await probe.duration(url: mixed)

        guard online, let system else {
            let transcript = try await transcriber.transcribe(audioURL: mixed, hint: context)
            let turns = await diarize(mic ?? mixed, relabel: TranscriptSegment.Label.unknown,
                                      note: &notes)
            var merged = TranscriptMerger.merge(transcript: transcript, diarization: turns)
            let refilled = try await recover(from: mixed, hint: context, into: merged,
                                             duration: duration) { raw in
                TranscriptMerger.merge(transcript: raw, diarization: turns)
            }
            merged = refilled.segments
            if let note = Self.recoveryNote(refilled) { notes.append(note) }
            return Result(
                segments: merged,
                diarizationNote: notes.isEmpty ? nil : notes.joined(separator: " "),
                coverage: coverage(of: merged, duration: duration,
                                   recovered: refilled.seconds))
        }

        let spoken = try await transcribeOther(system, hint: context, note: &notes)
        let others = spoken.segments
        var segments = others

        if let mic {
            let mine = try await transcriber.transcribe(audioURL: mic, hint: context)
                .map { segment in
                TranscriptSegment(speaker: TranscriptSegment.Label.me,
                                  start: segment.start + micStartOffset,
                                  end: segment.end + micStartOffset,
                                  text: segment.text)
            }
            let echo = EchoFilter.fold(mic: mine, against: others)
            if let note = EchoFilter.note(folded: echo.folded) { notes.append(note) }
            segments += echo.kept
        }
        if segments.isEmpty {
            notes.append("두 트랙 모두에서 발화를 찾지 못했습니다.")
        }
        var ordered = segments.sorted { $0.start < $1.start }

        let refilled = try await recover(from: system, hint: context, into: ordered,
                                         duration: duration) { raw in
            spoken.relabel(raw)
        }
        ordered = refilled.segments
        if let note = Self.recoveryNote(refilled) { notes.append(note) }

        return Result(segments: ordered,
                      diarizationNote: notes.isEmpty ? nil : notes.joined(separator: " "),
                      coverage: coverage(of: ordered, duration: duration,
                                         recovered: refilled.seconds))
    }

    private func coverage(of segments: [TranscriptSegment], duration: TimeInterval?,
                          recovered: TimeInterval = 0) -> TranscriptCoverage? {
        guard let duration, !segments.isEmpty else { return nil }
        return TranscriptCoverage.measure(segments: segments, duration: duration,
                                          recoveredSeconds: recovered)
    }

    private struct Refill {
        let segments: [TranscriptSegment]
        let seconds: TimeInterval
        let clips: Int
    }

    private func recover(from url: URL, hint: String?, into existing: [TranscriptSegment],
                         duration: TimeInterval?,
                         label: ([TranscriptSegment]) -> [TranscriptSegment]) async throws
    -> Refill {
        let empty = Refill(segments: existing, seconds: 0, clips: 0)
        guard let duration, !existing.isEmpty,
              let measured = TranscriptCoverage.measure(segments: existing, duration: duration),
              measured.hasLoss else { return empty }

        let raw: [TranscriptSegment]
        do {
            raw = try await transcriber.transcribe(audioURL: url, hint: hint,
                                                   clips: measured.gaps)
        } catch {
            return empty
        }
        let kept = TranscriptRecovery.accept(label(raw), into: existing, clips: measured.gaps)
        guard !kept.isEmpty else { return empty }

        let merged = (existing + kept).sorted { $0.start < $1.start }
        let after = TranscriptCoverage.measure(segments: merged, duration: duration)
        let regained = max(0, measured.missingSeconds - (after?.missingSeconds ?? 0))
        return Refill(segments: merged, seconds: regained,
                      clips: measured.gaps.count)
    }

    private static func recoveryNote(_ refill: Refill) -> String? {
        guard refill.seconds >= 1 else { return nil }
        return "1패스가 비운 \(refill.clips)곳 중 \(Int(refill.seconds.rounded()))초를"
            + " 재전사로 채웠습니다."
    }

    private func decodingHint(_ meetingHint: String?) -> String? {
        var parts: [String] = []
        if let meetingHint, !meetingHint.isEmpty { parts.append(meetingHint) }
        let terms = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { parts.append("용어: \(terms)") }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private struct SpokenTrack {
        let segments: [TranscriptSegment]
        let turns: [TranscriptSegment]

        func relabel(_ raw: [TranscriptSegment]) -> [TranscriptSegment] {
            guard !turns.isEmpty else {
                return raw.map {
                    TranscriptSegment(speaker: TranscriptSegment.Label.otherSingle,
                                      start: $0.start, end: $0.end, text: $0.text)
                }
            }
            return TranscriptMerger.merge(transcript: raw, diarization: turns)
        }
    }

    private func transcribeOther(_ system: URL, hint: String?,
                                 note notes: inout [String]) async throws -> SpokenTrack {
        let transcript = try await transcriber.transcribe(audioURL: system, hint: hint)
        guard diarizer != nil else {
            notes.append("화자 구분 스크립트가 없어 상대를 한 사람으로 묶었습니다.")
            let track = SpokenTrack(segments: [], turns: [])
            return SpokenTrack(segments: track.relabel(transcript), turns: [])
        }
        let turns = await diarize(system, relabel: TranscriptSegment.Label.other, note: &notes)
        let track = SpokenTrack(segments: [], turns: turns)
        return SpokenTrack(segments: track.relabel(transcript), turns: turns)
    }

    private func diarize(_ url: URL?, relabel: (Int) -> String,
                         note: inout [String]) async -> [TranscriptSegment] {
        guard let diarizer else {
            note.append("화자 구분 스크립트가 설정되지 않아 건너뛰었습니다.")
            return []
        }
        guard let url else {
            note.append("화자 구분에 쓸 원본 트랙이 없습니다.")
            return []
        }
        let turns: [TranscriptSegment]
        do {
            turns = try await diarizer.diarize(audioURL: url)
        } catch {
            note.append("화자 구분에 실패했습니다: \(error).")
            return []
        }
        guard !turns.isEmpty else {
            note.append("화자 구분이 \(url.lastPathComponent)에서 발화 구간을 찾지 못했습니다.")
            return []
        }
        var mapping: [String: String] = [:]
        return turns.map { turn in
            var relabeled = turn
            if let speaker = turn.speaker {
                if mapping[speaker] == nil { mapping[speaker] = relabel(mapping.count + 1) }
                relabeled.speaker = mapping[speaker]
            }
            return relabeled
        }
    }

    public func run(audioURL: URL) async throws -> [TranscriptSegment] {
        try await run(mixed: audioURL, system: nil, mic: nil).segments
    }
}

public protocol TrackProbing: Sendable {
    func hasSpeech(url: URL?) async -> Bool
    func duration(url: URL?) async -> TimeInterval?
}

public extension TrackProbing {
    func duration(url: URL?) async -> TimeInterval? {
        await AudioProbe.duration(url: url)
    }
}

public struct SignalTrackProbe: TrackProbing {
    public init() {}

    public func hasSpeech(url: URL?) async -> Bool {
        await AudioProbe.hasSpeech(url: url)
    }
}
