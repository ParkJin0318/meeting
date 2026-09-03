import Foundation
@preconcurrency import AVFoundation

public protocol AudioMixing: Sendable {
    func mixForTranscription(system: URL?, mic: URL?,
                             micStartOffset: TimeInterval) async throws -> URL?
}

public extension AudioMixing {
    func mixForTranscription(system: URL?, mic: URL?) async throws -> URL? {
        try await mixForTranscription(system: system, mic: mic, micStartOffset: 0)
    }
}

public struct AVFoundationAudioMixer: AudioMixing {
    public init() {}

    public func mixForTranscription(system: URL?, mic: URL?,
                                    micStartOffset: TimeInterval) async throws -> URL? {
        let candidates = [system, mic].compactMap { $0 }
        guard candidates.count == 2 else { return candidates.first }

        let composition = AVMutableComposition()
        var mixed: [URL] = []
        var assets: [AVURLAsset] = []
        for url in candidates {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let at = url == mic
                ? CMTime(seconds: micStartOffset, preferredTimescale: 600)
                : CMTime.zero
            try track.insertTimeRange(range, of: source, at: at)
            assets.append(asset)
            mixed.append(url)
        }
        guard mixed.count == 2 else {
            guard let survivor = mixed.first else {
                throw MixError.unreadable(candidates.map(\.lastPathComponent))
            }
            return survivor
        }

        let output = candidates[0].deletingPathExtension().appendingPathExtension("mixed.m4a")
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.exportUnavailable
        }
        try await session.export(to: output, as: .m4a)
        withExtendedLifetime(assets) {}
        return output
    }

    public enum MixError: Error, CustomStringConvertible {
        case unreadable([String])
        case exportUnavailable

        public var description: String {
            switch self {
            case .unreadable(let files):
                return "오디오 트랙을 읽을 수 없습니다: \(files.joined(separator: ", "))"
            case .exportUnavailable:
                return "오디오 합성 세션을 만들 수 없습니다"
            }
        }
    }
}
