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

    private static let workers = 4

    public func transcribe(audioURL: URL, hint: String?) async throws -> [TranscriptSegment] {
        let handle = try await loader.kit()
        var samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        AudioGain.normalizeWindowed(&samples, sampleRate: Double(WhisperKit.sampleRate))
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
            let start = max(0, clip.start - Self.clipPadding)
            let end = min(Double(all.count) / rate, clip.end + Self.clipPadding)
            let lower = Int(start * rate)
            let upper = min(all.count, Int(end * rate))
            guard upper - lower > Int(rate / 2) else { continue }

            var slice = Array(all[lower..<upper])
            AudioGain.normalize(&slice)
            // 빈 구간은 "여기 말이 있는데 1패스가 놓쳤다"가 이미 판정된 자리다 — 그 구간에
            // 에너지 게이트를 다시 씌우면 1패스를 막은 문에 재전사가 똑같이 막힌다.
            // chunking 을 끄면 WhisperKit 이 30초 창 순차로 전부 디코딩한다.
            guard let results = try? await Self.infer(
                handle, audio: slice, hint: hint, language: language,
                chunking: nil, noSpeechThreshold: Self.retryNoSpeechThreshold) else {
                continue
            }
            recovered += Self.segments(from: results).map {
                TranscriptSegment(speaker: $0.speaker, start: $0.start + start,
                                  end: $0.end + start, text: $0.text)
            }
        }
        return recovered.sorted { $0.start < $1.start }
    }

    private static let clipPadding: TimeInterval = 2
    private static let retryNoSpeechThreshold: Float = 0.9

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

    // .vad 는 긴 무음을 건너뛰어 빠르지만, WhisperKit 이 쓰는 EnergyVAD 기본 임계(프레임 RMS 0.02)는
    // AudioGain 이 말소리를 목표 0.08 까지 올려놨다는 전제에서만 안전하다. 증폭이 걸리지 않은
    // 조용한 녹음에서는 이 문이 통째로 닫힌다 — 그래서 재전사 경로는 chunking 을 끄고 부른다.
    private nonisolated static func infer(
        _ handle: WhisperKitHandle, audio: [Float], hint: String?, language: String,
        chunking: ChunkingStrategy? = .vad,
        noSpeechThreshold: Float? = nil) async throws -> [TranscriptionResult] {
        var options = DecodingOptions(language: language, skipSpecialTokens: true,
                                      concurrentWorkerCount: workers,
                                      chunkingStrategy: chunking)
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
