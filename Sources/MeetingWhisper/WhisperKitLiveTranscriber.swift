import Foundation
import AVFoundation
import MeetingCore
import WhisperKit

private final class LiveAudioInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LiveTrack: [Float]] = [:]
    private var rates: [LiveTrack: Double] = [:]
    private let capSeconds: Double = 40

    func append(_ samples: [Float], rate: Double, track: LiveTrack) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            var buffer = pending[track, default: []]
            buffer.append(contentsOf: samples)
            let cap = Int(capSeconds * rate)
            if buffer.count > cap { buffer.removeFirst(buffer.count - cap) }
            pending[track] = buffer
            rates[track] = rate
        }
    }

    func drain() -> [(track: LiveTrack, samples: [Float], rate: Double)] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending.compactMap { track, samples in
                guard let rate = rates[track] else { return nil }
                return (track, samples, rate)
            }
        }
    }

    func reset() {
        lock.withLock { pending.removeAll() }
    }
}

public actor WhisperKitLiveTranscriber: LiveTranscribing {
    private static let maxWindow: TimeInterval = 28
    private static let minWindow: TimeInterval = 4
    private static let sampleRate: Double = 16_000

    private let loader: WhisperKitLoader
    private let language: String
    private let inbox = LiveAudioInbox()

    private var tracks: [LiveTrack: TrackState] = [:]
    private var loop: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<LiveTranscriptUpdate>.Continuation] = [:]
    private var notice: String?

    public init(loader: WhisperKitLoader, language: String = "ko") {
        self.loader = loader
        self.language = language
    }

    private struct TrackState {
        var samples: [Float] = []
        var baseIndex: Int = 0
        var confirmed: [TranscriptSegment] = []
        var pending: String = ""
    }

    public func prewarm() async {
        _ = try? await loader.kit()
    }

    public func start() async {
        inbox.reset()
        tracks = [:]
        notice = nil
        publish()
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() async -> [TranscriptSegment] {
        loop?.cancel()
        loop = nil
        let segments = mergedConfirmed()
        inbox.reset()
        for listener in listeners.values { listener.finish() }
        listeners = [:]
        return segments
    }

    public nonisolated func updates() -> AsyncStream<LiveTranscriptUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.detach(id) }
            }
            Task { await self.attach(continuation, id: id) }
        }
    }

    private func attach(_ continuation: AsyncStream<LiveTranscriptUpdate>.Continuation,
                        id: UUID) {
        listeners[id] = continuation
        publish()
    }

    private func detach(_ id: UUID) {
        listeners[id] = nil
    }

    private func run() async {
        notice = "전사 모델을 준비하는 중입니다. 첫 실행은 내려받기와 컴파일로 수 분 걸리고, 녹음은 그대로 계속됩니다."
        publish()
        guard let handle = try? await loader.kit() else {
            notice = "라이브 전사 모델을 적재하지 못했습니다. 종료 후 전사는 정상 진행됩니다."
            publish()
            return
        }
        guard !Task.isCancelled else { return }
        notice = nil
        ingest(trimTo: Self.maxWindow)
        publish()
        while !Task.isCancelled {
            ingest()
            var changed = false
            for track in LiveTrack.allCases where !Task.isCancelled {
                if await step(track: track, handle: handle) { changed = true }
            }
            if changed { publish() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func ingest(trimTo seconds: TimeInterval? = nil) {
        for item in inbox.drain() {
            let converted = Self.resample(item.samples, from: item.rate)
            guard !converted.isEmpty else { continue }
            var state = tracks[item.track, default: TrackState()]
            state.samples.append(contentsOf: converted)
            if let seconds {
                let keep = Int(seconds * Self.sampleRate)
                let excess = state.samples.count - keep
                if excess > 0 {
                    state.samples.removeFirst(excess)
                    state.baseIndex += excess
                }
            }
            tracks[item.track] = state
        }
    }

    private nonisolated static func infer(
        _ handle: WhisperKitHandle, audio: [Float],
        language: String) async throws -> [TranscriptionResult] {
        let options = DecodingOptions(language: language, skipSpecialTokens: true)
        return try await handle.kit.transcribe(audioArray: audio, decodeOptions: options)
    }

    private func step(track: LiveTrack, handle: WhisperKitHandle) async -> Bool {
        guard var state = tracks[track] else { return false }
        let window = Double(state.samples.count) / Self.sampleRate
        guard window >= Self.minWindow else { return false }

        let level = AudioGain.measure(state.samples, sampleRate: Self.sampleRate)
        guard AudioGain.hasSpeech(level) else {
            state.baseIndex += state.samples.count
            state.samples = []
            let hadPending = !state.pending.isEmpty
            state.pending = ""
            tracks[track] = state
            return hadPending
        }

        let base = Double(state.baseIndex) / Self.sampleRate
        let samples = AudioGain.amplified(state.samples, by: AudioGain.factor(for: level))
        guard let results = try? await Self.infer(handle, audio: samples,
                                                  language: language) else {
            return false
        }
        let segments = results.flatMap(\.segments)
            .map { segment in
                TranscriptSegment(speaker: track.speaker,
                                  start: base + Double(segment.start),
                                  end: base + Double(segment.end),
                                  text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .filter { !$0.text.isEmpty }
        guard !segments.isEmpty else {
            if window >= Self.maxWindow {
                state.baseIndex += state.samples.count
                state.samples = []
                tracks[track] = state
            }
            return false
        }

        let split = LiveAudio.split(segments: segments, base: base,
                                    full: window >= Self.maxWindow,
                                    sampleRate: Self.sampleRate, available: state.samples.count)
        state.pending = split.pending
        state.confirmed.append(contentsOf: split.confirmed)
        state.samples.removeFirst(split.drop)
        state.baseIndex += split.drop
        tracks[track] = state
        return true
    }

    private func publish() {
        let update = LiveTranscriptUpdate(
            confirmed: mergedConfirmed(),
            pending: LiveTrack.allCases.compactMap { tracks[$0]?.pending }
                .first { !$0.isEmpty } ?? "",
            notice: notice)
        for listener in listeners.values { listener.yield(update) }
    }

    private func mergedConfirmed() -> [TranscriptSegment] {
        LiveTrack.allCases.flatMap { tracks[$0]?.confirmed ?? [] }
            .sorted { $0.start < $1.start }
    }

    private static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != sampleRate else { return samples }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        guard let converted = AudioProcessor.resampleAudio(fromBuffer: buffer,
                                                           toSampleRate: sampleRate,
                                                           channelCount: 1) else { return [] }
        return AudioProcessor.convertBufferToArray(buffer: converted)
    }
}

extension WhisperKitLiveTranscriber: LiveAudioSink {
    public nonisolated func append(samples: [Float], sampleRate: Double, track: LiveTrack) {
        inbox.append(samples, rate: sampleRate, track: track)
    }
}
