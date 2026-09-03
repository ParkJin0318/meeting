import Foundation
@preconcurrency import AVFoundation

public enum LiveTrack: String, Sendable, CaseIterable {
    case mic, system

    public var speaker: String {
        switch self {
        case .mic: TranscriptSegment.Label.me
        case .system: TranscriptSegment.Label.otherSingle
        }
    }
}

public protocol LiveAudioSink: Sendable {
    func append(samples: [Float], sampleRate: Double, track: LiveTrack)
}

public protocol LiveTranscribing: Sendable {
    func prewarm() async
    func start() async
    func stop() async -> [TranscriptSegment]
    func updates() -> AsyncStream<LiveTranscriptUpdate>
}

public struct LiveTranscriptUpdate: Sendable, Equatable {
    public let confirmed: [TranscriptSegment]
    public let pending: String
    public let notice: String?

    public init(confirmed: [TranscriptSegment], pending: String = "", notice: String? = nil) {
        self.confirmed = confirmed
        self.pending = pending
        self.notice = notice
    }
}

public enum LiveAudio {
    public static func split(segments: [TranscriptSegment], base: Double, full: Bool,
                             sampleRate: Double,
                             available: Int) -> (confirmed: [TranscriptSegment],
                                                 pending: String, drop: Int) {
        guard !segments.isEmpty else { return ([], "", full ? available : 0) }
        let confirmable = full ? segments : Array(segments.dropLast())
        let pending = full ? "" : (segments.last?.text ?? "")
        guard let last = confirmable.last else { return ([], pending, 0) }
        let drop = min(max(Int((last.end - base) * sampleRate), 0), available)
        return (confirmable, pending, drop)
    }

    public static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        if buffer.format.isInterleaved {
            let stride = buffer.stride
            let pointer = data[0]
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += pointer[frame * stride + channel] }
                return sum / Float(channels)
            }
        }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channels { sum += data[channel][frame] }
            return sum / Float(channels)
        }
    }
}
