import Foundation

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case scheduled
        case recording
        case transcribing
        case summarizing
        case done
        case failed
    }

    public struct Origin: Codable, Sendable, Hashable {
        public var appName: String
        public var bundleID: String
        public var windowTitle: String

        public init(appName: String, bundleID: String, windowTitle: String) {
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
        }
    }

    public var id: String
    public var title: String
    public var scheduledAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// 일시 중지로 빠진 벽시계 시간. 파일에는 남지 않으므로 길이 계산에서 뺀다.
    public var pausedSeconds: TimeInterval
    public var status: Status
    public var systemAudioPath: String?
    public var micAudioPath: String?
    public var mixedAudioPath: String?
    public var segments: [TranscriptSegment]
    public var speakerNames: [String: String]
    public var speakerNameSuggestions: [String: String]
    public var diarizationNote: String?
    public var coverage: TranscriptCoverage?
    public var origin: Origin?
    public var transcript: String
    public var summary: String
    public var failureReason: String?
    public var vaultNotePath: String?
    public var vaultTranscriptPath: String?

    public init(id: String = UUID().uuidString, title: String, scheduledAt: Date = Date(),
                startedAt: Date? = nil, endedAt: Date? = nil, pausedSeconds: TimeInterval = 0,
                status: Status = .scheduled,
                systemAudioPath: String? = nil, micAudioPath: String? = nil,
                mixedAudioPath: String? = nil,
                segments: [TranscriptSegment] = [],
                speakerNames: [String: String] = [:],
                speakerNameSuggestions: [String: String] = [:],
                diarizationNote: String? = nil, coverage: TranscriptCoverage? = nil,
                origin: Origin? = nil,
                transcript: String = "", summary: String = "", failureReason: String? = nil,
                vaultNotePath: String? = nil, vaultTranscriptPath: String? = nil) {
        self.id = id
        self.title = title
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.status = status
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.mixedAudioPath = mixedAudioPath
        self.segments = segments
        self.speakerNames = speakerNames
        self.speakerNameSuggestions = speakerNameSuggestions
        self.diarizationNote = diarizationNote
        self.coverage = coverage
        self.origin = origin
        self.transcript = transcript
        self.summary = summary
        self.failureReason = failureReason
        self.vaultNotePath = vaultNotePath
        self.vaultTranscriptPath = vaultTranscriptPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        scheduledAt = try c.decode(Date.self, forKey: .scheduledAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        pausedSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedSeconds) ?? 0
        status = try c.decode(Status.self, forKey: .status)
        systemAudioPath = try c.decodeIfPresent(String.self, forKey: .systemAudioPath)
        micAudioPath = try c.decodeIfPresent(String.self, forKey: .micAudioPath)
        mixedAudioPath = try c.decodeIfPresent(String.self, forKey: .mixedAudioPath)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        speakerNameSuggestions = try c.decodeIfPresent(
            [String: String].self, forKey: .speakerNameSuggestions) ?? [:]
        diarizationNote = try c.decodeIfPresent(String.self, forKey: .diarizationNote)
        coverage = try c.decodeIfPresent(TranscriptCoverage.self, forKey: .coverage)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        vaultNotePath = try c.decodeIfPresent(String.self, forKey: .vaultNotePath)
        vaultTranscriptPath = try c.decodeIfPresent(String.self, forKey: .vaultTranscriptPath)
    }
}

extension Meeting {
    public func playbackURL(
        existingFile: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        var candidates: [String] = []
        if let mixedAudioPath { candidates.append(mixedAudioPath) }
        if let systemAudioPath {
            candidates.append(URL(fileURLWithPath: systemAudioPath)
                .deletingPathExtension().appendingPathExtension("mixed.m4a").path)
        }
        if let micAudioPath { candidates.append(micAudioPath) }
        if let systemAudioPath { candidates.append(systemAudioPath) }
        return candidates.first(where: existingFile).map { URL(fileURLWithPath: $0) }
    }

    public var canReprocess: Bool {
        guard status == .failed || status == .done else { return false }
        let fm = FileManager.default
        return [systemAudioPath, micAudioPath].compactMap { $0 }
            .contains { fm.fileExists(atPath: $0) }
    }

    public var reprocessesSummaryOnly: Bool {
        if status == .done { return true }
        return failureReason?.hasPrefix("요약 실패") == true
    }

    public func displayName(for label: String) -> String {
        TranscriptMerger.resolve(label, in: speakerNames)
    }

    public var displaySegments: [TranscriptSegment] {
        segments.isEmpty ? TranscriptSegment.parseLegacy(transcript) : segments
    }

    public var speakerLabels: [String] {
        var seen: Set<String> = []
        return displaySegments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    public var transcriptionHint: String {
        var parts: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { parts.append(trimmedTitle) }
        let names = speakerNames.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        if !names.isEmpty { parts.append("참석자: " + names.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }
}

public struct RecordedAudio: Sendable {
    public let systemAudioURL: URL?
    public let micURL: URL?
    public let micStartOffset: TimeInterval

    public init(systemAudioURL: URL?, micURL: URL?, micStartOffset: TimeInterval = 0) {
        self.systemAudioURL = systemAudioURL
        self.micURL = micURL
        self.micStartOffset = max(0, micStartOffset)
    }
}

public protocol MeetingRecording: Sendable {
    func start(meetingID: String) async throws
    func stop() async throws -> RecordedAudio
    func micLevels() -> AsyncStream<Float>
    /// 일시 중지. 캡처는 계속 돌리고 파일 쓰기와 라이브 전달만 막는다 — 재개하면 같은 파일에 이어 쓴다.
    /// 동기여야 한다: `MeetingCenter`가 suspension 없이 종료와 순서를 맞춘다.
    func setPaused(_ paused: Bool)
}

extension MeetingRecording {
    public func micLevels() -> AsyncStream<Float> {
        AsyncStream { $0.finish() }
    }

    public func setPaused(_ paused: Bool) {}
}

public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var speaker: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: String? = nil, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

extension TranscriptSegment {
    public enum Label {
        public static let me = "나"
        public static let otherSingle = "상대"
        public static func other(_ index: Int) -> String { "상대\(index)" }
        public static func unknown(_ index: Int) -> String { "화자\(index)" }
    }

    public static func parseLegacy(_ plainText: String) -> [TranscriptSegment] {
        plainText.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> TranscriptSegment? in
                let line = String(rawLine)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
                    return TranscriptSegment(start: -1, end: -1, text: line)
                }
                let stamp = line[line.index(after: line.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                let numbers = parts.compactMap { TimeInterval($0) }
                guard numbers.count == parts.count, !numbers.isEmpty else {
                    return TranscriptSegment(start: -1, end: -1, text: line)
                }
                let start = numbers.reduce(0) { $0 * 60 + $1 }
                var body = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
                var speaker: String?
                if let colon = body.firstIndex(of: ":") {
                    let candidate = String(body[body.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty, candidate.count <= 24,
                       !candidate.contains(" ") {
                        speaker = candidate
                        body = String(body[body.index(after: colon)...])
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                return TranscriptSegment(speaker: speaker, start: start, end: start, text: body)
            }
    }

    public var isSeekable: Bool { start >= 0 }
}

public protocol Transcribing: Sendable {
    func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment]

    func transcribe(audioURL: URL, hint: String?,
                    clips: [TranscriptCoverage.Gap]) async throws -> [TranscriptSegment]
}

public extension Transcribing {
    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        try await transcribe(audioURL: audioURL, hint: nil)
    }

    func transcribe(audioURL: URL, hint: String?,
                    clips: [TranscriptCoverage.Gap]) async throws -> [TranscriptSegment] {
        []
    }
}

public protocol Diarizing: Sendable {
    func diarize(audioURL: URL) async throws -> [TranscriptSegment]
}

public enum TranscriptMerger {
    public static func merge(transcript: [TranscriptSegment],
                             diarization: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !diarization.isEmpty else { return transcript }
        return transcript.map { segment in
            var merged = segment
            var bestOverlap: TimeInterval = 0
            for turn in diarization {
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                if overlap > bestOverlap, let speaker = turn.speaker {
                    bestOverlap = overlap
                    merged.speaker = speaker
                }
            }
            return merged
        }
    }

    public static func plainText(_ segments: [TranscriptSegment],
                                 names: [String: String] = [:],
                                 gaps: [TranscriptCoverage.Gap] = []) -> String {
        let rows = segments.map { (at: $0.start, hole: false, text: line($0, names: names)) }
            + gaps.map { gap in
                (at: gap.start, hole: true,
                 text: "[\(clock(gap.start))] ⟨전사 없음 · \(Int(gap.duration.rounded()))초⟩")
            }
        return rows
            .sorted { ($0.at, $0.hole ? 1 : 0) < ($1.at, $1.hole ? 1 : 0) }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func line(_ segment: TranscriptSegment, names: [String: String]) -> String {
        let time = clock(segment.start)
        guard let speaker = segment.speaker else { return "[\(time)] \(segment.text)" }
        return "[\(time)] \(resolve(speaker, in: names)): \(segment.text)"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60)
    }

    static func resolve(_ label: String, in names: [String: String]) -> String {
        let name = names[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil) ?? label
    }
}
