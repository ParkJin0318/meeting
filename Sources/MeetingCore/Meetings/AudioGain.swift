import Foundation

public struct AudioLevel: Sendable, Equatable {
    public let noise: Float
    public let speech: Float
    public let peak: Float

    public init(noise: Float, speech: Float, peak: Float) {
        self.noise = noise
        self.speech = speech
        self.peak = peak
    }

    public var dynamicRange: Float {
        guard noise > 0 else { return speech > 0 ? .greatestFiniteMagnitude : 0 }
        return speech / noise
    }
}

public enum AudioGain {
    public static let frameMillis: Double = 100

    static let targetSpeech: Float = 0.08
    static let headroom: Float = 0.97
    static let maxGain: Float = 20

    static let speechFloor: Float = 0.0005
    static let speechDynamicRange: Float = 3.0

    public static func measure(_ samples: [Float], sampleRate: Double = 16_000) -> AudioLevel {
        guard !samples.isEmpty else { return AudioLevel(noise: 0, speech: 0, peak: 0) }
        let frameLength = max(1, Int(sampleRate * frameMillis / 1000))
        let capacity = samples.count / frameLength + 1
        var levels: [Float] = []
        var peaks: [Float] = []
        levels.reserveCapacity(capacity)
        peaks.reserveCapacity(capacity)
        var index = 0
        while index < samples.count {
            let end = min(index + frameLength, samples.count)
            var sum: Float = 0
            var top: Float = 0
            for position in index..<end {
                let sample = samples[position]
                sum += sample * sample
                top = max(top, abs(sample))
            }
            levels.append((sum / Float(end - index)).squareRoot())
            peaks.append(top)
            index = end
        }
        levels.sort()
        peaks.sort()
        return AudioLevel(noise: percentile(levels, 0.10),
                          speech: percentile(levels, 0.95),
                          peak: percentile(peaks, 0.99))
    }

    public static func hasSpeech(_ level: AudioLevel) -> Bool {
        level.speech >= speechFloor && level.dynamicRange >= speechDynamicRange
    }

    public static func factor(for level: AudioLevel) -> Float {
        guard hasSpeech(level), level.speech > 0 else { return 1 }
        let wanted = targetSpeech / level.speech
        let clipLimit = level.peak > 0 ? headroom / level.peak : maxGain
        return min(max(min(wanted, clipLimit), 1), maxGain)
    }

    public static func normalized(_ samples: [Float]) -> [Float] {
        amplified(samples, by: factor(for: measure(samples)))
    }

    public static func normalize(_ samples: inout [Float]) {
        let gain = factor(for: measure(samples))
        guard gain > 1.001 else { return }
        for index in samples.indices {
            samples[index] = min(max(samples[index] * gain, -1), 1)
        }
    }

    public static let gainWindowSeconds: Double = 30

    public static func normalizeWindowed(_ samples: inout [Float], sampleRate: Double = 16_000,
                                         windowSeconds: Double = gainWindowSeconds) {
        let windowLength = max(1, Int(sampleRate * windowSeconds))
        guard samples.count > windowLength else { return normalize(&samples) }

        var gains: [Float] = []
        var centers: [Int] = []
        gains.reserveCapacity(samples.count / windowLength + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + windowLength, samples.count)
            gains.append(factor(for: measure(Array(samples[index..<end]), sampleRate: sampleRate)))
            centers.append((index + end) / 2)
            index = end
        }
        guard gains.contains(where: { $0 > 1.001 }), let last = centers.last else { return }

        ramp(&samples, from: gains[0], to: gains[0], in: 0..<centers[0])
        for index in 1..<centers.count {
            ramp(&samples, from: gains[index - 1], to: gains[index],
                 in: centers[index - 1]..<centers[index])
        }
        ramp(&samples, from: gains[gains.count - 1], to: gains[gains.count - 1],
             in: last..<samples.count)
    }

    private static func ramp(_ samples: inout [Float], from start: Float, to end: Float,
                             in range: Range<Int>) {
        guard !range.isEmpty else { return }
        let span = Float(range.count)
        for position in range {
            let gain = start + (end - start) * (Float(position - range.lowerBound) / span)
            guard gain > 1.001 else { continue }
            samples[position] = min(max(samples[position] * gain, -1), 1)
        }
    }

    public static func amplified(_ samples: [Float], by gain: Float) -> [Float] {
        guard gain > 1.001 else { return samples }
        return samples.map { min(max($0 * gain, -1), 1) }
    }

    private static func percentile(_ sorted: [Float], _ ratio: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * ratio)))
        return sorted[index]
    }
}
