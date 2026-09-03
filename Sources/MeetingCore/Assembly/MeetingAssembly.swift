import Foundation

public struct MeetingServices: Sendable {
    public let center: MeetingCenter
    public let recorder: any MeetingRecording
    public let callDetector: CallDetector
    public let live: (any LiveTranscribing)?
    public let diarization: DiarizationSetup
    public let vaultNotice: String?
    public let summaryNotice: String?
    public let warmUp: @Sendable () async -> Bool
    public let modelReady: @Sendable () -> Bool
}

public enum MeetingAssembly {
    public static func assemble(settings: MeetingSettings,
                                profile: MeetingHostProfile,
                                store: any MeetingStoring,
                                notifier: any MeetingNotifying,
                                transcriber: any Transcribing,
                                live: (any LiveTranscribing & LiveAudioSink)?,
                                vaultRoot: URL? = nil,
                                generator: String = "meeting-app/dev",
                                runner: any ProcessRunning = ShellProcessRunner(),
                                warmUp: @escaping @Sendable () async -> Bool = { false },
                                modelReady: @escaping @Sendable () -> Bool = { false }) -> MeetingServices {
        let recorder = SystemAudioMeetingRecorder(
            recordingsDirectory: profile.paths.recordings,
            tapName: profile.audioTapName,
            live: live, boostsInputVolume: settings.boostInputVolume)

        let diarization = DiarizationSetup(supportRoot: profile.paths.diarization)
        let diarizer = diarization.scriptPath.map {
            SherpaDiarizer(scriptPath: $0, supportRoot: profile.paths.diarization, runner: runner)
        }
        let transcription = LocalTranscriptionPipeline(
            transcriber: transcriber, diarizer: diarizer,
            glossary: settings.transcriptionGlossary)

        let executable = settings.claudeExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarizer: ClaudeSummarizer? = settings.summarizes ? ClaudeSummarizer(
            configuration: .init(executable: executable,
                                 workingDirectory: profile.paths.supportDirectory),
            runner: runner) : nil

        let resolvedVault = vaultRoot ?? resolveVaultRoot(settings.vaultPath)
        let vault = resolvedVault.map {
            MeetingVaultExporter(vaultRoot: $0, generator: generator, runner: runner)
        }
        let notice: String? = resolvedVault == nil && !settings.vaultPath
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "vault 경로(\(settings.vaultPath))를 찾지 못해 미팅 요약이 노트로 나가지 않습니다."
            : nil

        let center = MeetingCenter(
            store: store, recorder: recorder, transcription: transcription,
            analyzer: summarizer, notifier: notifier, vault: vault, live: live,
            glossary: settings.transcriptionGlossary,
            summaryLanguage: settings.transcriptionLanguage,
            hostDisplayName: profile.displayName)

        return MeetingServices(
            center: center, recorder: recorder,
            callDetector: CallDetector(), live: live,
            diarization: diarization, vaultNotice: notice,
            summaryNotice: summarizer == nil
                ? "요약기(claude) 경로가 비어 있어 미팅을 전사까지만 만듭니다."
                : nil,
            warmUp: warmUp, modelReady: modelReady)
    }

    public static func resolveVaultRoot(_ path: String,
                                        fileManager: FileManager = .default) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(atPath: root.appendingPathComponent("wiki").path,
                                     isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root
    }
}
