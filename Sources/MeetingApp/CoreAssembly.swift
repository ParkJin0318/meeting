import Foundation
import MeetingCore
import MeetingWhisper

enum CoreAssembly {
    static func assemble(settings: MeetingSettings, profile: MeetingHostProfile,
                         store: any MeetingStoring,
                         notifier: any MeetingNotifying) -> MeetingServices {
        let loader = WhisperKitLoader(downloadBase: profile.paths.models)
        let live = settings.liveTranscription
            ? WhisperKitLiveTranscriber(loader: loader, language: settings.transcriptionLanguage)
            : nil
        return MeetingAssembly.assemble(
            settings: settings, profile: profile, store: store, notifier: notifier,
            transcriber: WhisperKitTranscriber(loader: loader,
                                               language: settings.transcriptionLanguage),
            live: live, generator: generator,
            warmUp: { await loader.prewarm() },
            modelReady: { loader.isDownloaded() })
    }

    static var generator: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "meeting-app/\(version ?? "dev")"
    }

    static func defaultSettings() -> MeetingSettings {
        var settings = MeetingSettings()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            settings.claudeExecutable = candidate
            break
        }
        return settings
    }
}
