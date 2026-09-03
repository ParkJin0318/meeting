import Foundation
@preconcurrency import AVFoundation

public enum AudioProbe {
    static let windowSeconds: TimeInterval = 0.25
    static let voicedThreshold: Float = 0.012
    static let minimumTurnSeconds: TimeInterval = 0.6
    static let joinGapSeconds: TimeInterval = 0.8
    static let minimumSpeechSeconds: TimeInterval = 3.0

    public static func hasSpeech(url: URL?) async -> Bool {
        guard let url else { return false }
        let turns = await voicedTurns(url: url, label: nil)
        let total = turns.reduce(0) { $0 + ($1.end - $1.start) }
        return total >= minimumSpeechSeconds
    }

    public static func voicedTurns(url: URL, label: String?) async -> [TranscriptSegment] {
        let levels = (try? await windowLevels(url: url)) ?? []
        var turns: [TranscriptSegment] = []
        var openedAt: TimeInterval?
        for (index, level) in levels.enumerated() {
            let time = TimeInterval(index) * windowSeconds
            if level >= voicedThreshold {
                if openedAt == nil { openedAt = time }
            } else if let start = openedAt {
                turns.append(TranscriptSegment(speaker: label, start: start, end: time, text: ""))
                openedAt = nil
            }
        }
        if let start = openedAt {
            turns.append(TranscriptSegment(speaker: label, start: start,
                                           end: TimeInterval(levels.count) * windowSeconds,
                                           text: ""))
        }
        return tidy(turns)
    }

    static func tidy(_ turns: [TranscriptSegment]) -> [TranscriptSegment] {
        var joined: [TranscriptSegment] = []
        for turn in turns {
            if var last = joined.last, turn.start - last.end <= joinGapSeconds {
                last.end = turn.end
                joined[joined.count - 1] = last
            } else {
                joined.append(turn)
            }
        }
        return joined.filter { $0.end - $0.start >= minimumTurnSeconds }
    }

    public static func duration(url: URL?) async -> TimeInterval? {
        guard let url else { return nil }
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func windowLevels(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let sampleRate: Double = 16_000
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let windowFrames = Int(sampleRate * windowSeconds)
        var levels: [Float] = []
        var carrySum: Float = 0
        var carryCount = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for index in 0..<(length / 4) {
                    let sample = samples[index]
                    carrySum += sample * sample
                    carryCount += 1
                    if carryCount == windowFrames {
                        levels.append((carrySum / Float(carryCount)).squareRoot())
                        carrySum = 0
                        carryCount = 0
                    }
                }
            }
        }
        if carryCount > 0 { levels.append((carrySum / Float(carryCount)).squareRoot()) }
        return levels
    }
}
