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

    private nonisolated static func infer(
        _ handle: WhisperKitHandle, audio: [Float], hint: String?, language: String,
        noSpeechThreshold: Float? = nil) async throws -> [TranscriptionResult] {
        var options = DecodingOptions(language: language, skipSpecialTokens: true,
                                      concurrentWorkerCount: workers,
                                      chunkingStrategy: .vad)
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
