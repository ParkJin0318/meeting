import Foundation
import MeetingCore
import WhisperKit

public actor WhisperKitTranscriber: Transcribing {
    private let loader: WhisperKitLoader
    private let language: String

    public init(loader: WhisperKitLoader, language: String = "ko") {
        self.loader = loader
        self.language = language
    }

    public func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        let handle = try await loader.kit()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let results = try await Self.infer(handle, audio: samples,
                                           hint: hint, language: language)
        return Self.segments(from: results)
    }

    public func transcribe(audioURL: URL, hint: String?,
                           clips: [TranscriptCoverage.Gap]) async throws -> [TranscriptSegment] {
        guard !clips.isEmpty else { return [] }
        let handle = try await loader.kit()
        let rate = Double(WhisperKit.sampleRate)
        let all = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)

        var recovered: [TranscriptSegment] = []
        for clip in clips {
            let start = max(0, clip.start)
            let lower = Int(start * rate)
            let upper = min(all.count, Int(clip.end * rate))
            guard upper - lower > Int(rate / 2) else { continue }

            let slice = Array(all[lower..<upper])
            guard let results = try? await Self.infer(
                handle, audio: slice, hint: hint, language: language,
                noSpeechThreshold: Self.retryNoSpeechThreshold) else {
                continue
            }
            recovered += Self.segments(from: results).map {
                TranscriptSegment(speaker: $0.speaker, start: $0.start + start,
                                  end: $0.end + start, text: $0.text)
            }
        }
        return recovered.sorted { $0.start < $1.start }
    }

    // 재전사에서 완화하는 건 이것 하나뿐이다. 압축률·로그확률·온도 폴백은 환각 루프 차단기라
    // 풀면 같은 문장이 수백 줄 나온다.
    private static let retryNoSpeechThreshold: Float = 0.95

    private static func segments(from results: [TranscriptionResult]) -> [TranscriptSegment] {
        results.flatMap(\.segments)
            .compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(start: Double(segment.start),
                                         end: Double(segment.end),
                                         text: text)
            }
            .sorted { $0.start < $1.start }
    }

    // 파일 전사는 30초 창을 처음부터 끝까지 순차로 디코딩한다 — 청킹·게인·첫 토큰 폴백 없음.
    // 셋 다 창을 통째로 버리는 문이었다: 15분 강의 클립에서 .vad+게인은 459초를 비웠고 셋을 걷자
    // 151초로 줄었다(mlx-whisper 순차 디코딩 104초, 실측 2026-09-30). 순차가 더 빠르기도 했다(363→229초).
    // 첫 토큰 폴백(-1.5)은 OpenAI whisper 에 없는 WhisperKit 전용 규칙이다.
    private nonisolated static func infer(
        _ handle: WhisperKitHandle, audio: [Float], hint: String?, language: String,
        noSpeechThreshold: Float? = nil) async throws -> [TranscriptionResult] {
        var options = DecodingOptions(language: language, skipSpecialTokens: true,
                                      firstTokenLogProbThreshold: nil)
        options.promptTokens = promptTokens(for: hint, kit: handle.kit)
        if let noSpeechThreshold { options.noSpeechThreshold = noSpeechThreshold }
        return try await handle.kit.transcribe(audioArray: audio, decodeOptions: options)
    }

    private nonisolated static func promptTokens(for hint: String?, kit: WhisperKit) -> [Int]? {
        guard let hint, !hint.isEmpty, let tokenizer = kit.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + hint)
        return tokens.isEmpty ? nil : tokens
    }
}
