import Foundation
import MeetingCore
import WhisperKit

struct WhisperKitHandle: @unchecked Sendable {
    let kit: WhisperKit
}

public actor WhisperKitLoader {
    public static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

    private let model: String
    private let downloadBase: URL
    private var loaded: WhisperKitHandle?
    private var loading: Task<WhisperKitHandle, Error>?

    public init(model: String = WhisperKitLoader.defaultModel, downloadBase: URL) {
        self.model = model
        self.downloadBase = downloadBase
    }

    nonisolated public func isDownloaded(fileManager: FileManager = .default) -> Bool {
        let root = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model)
        return ["config.json",
                "TextDecoder.mlmodelc/coremldata.bin",
                "AudioEncoder.mlmodelc/coremldata.bin"].allSatisfy {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    @discardableResult
    public func prewarm() async -> Bool {
        (try? await kit()) != nil
    }

    func kit() async throws -> WhisperKitHandle {
        if let loaded { return loaded }
        if let loading { return try await loading.value }
        let model = self.model
        let downloadBase = self.downloadBase
        let task = Task {
            WhisperKitHandle(kit: try await WhisperKit(WhisperKitConfig(
                model: model, downloadBase: downloadBase, verbose: false, logLevel: .error,
                prewarm: false, download: true)))
        }
        loading = task
        do {
            let kit = try await task.value
            loaded = kit
            loading = nil
            return kit
        } catch {
            loading = nil
            throw error
        }
    }
}
