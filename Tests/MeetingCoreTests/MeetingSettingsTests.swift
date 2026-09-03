import Testing
import Foundation
@testable import MeetingCore

@Suite struct MeetingSettingsTests {
    @Test func decodesEmptyObjectWithDefaults() throws {
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data("{}".utf8))
        #expect(decoded == MeetingSettings())
        #expect(decoded.vaultPath == "", "노트 내보내기는 기본이 꺼짐이다 — 남의 볼트 경로를 짐작하지 않는다")
        #expect(decoded.transcriptionLanguage == "ko")
        #expect(decoded.liveTranscription)
        #expect(decoded.boostInputVolume)
    }

    @Test func keepsStoredVaultPathWhenDefaultChanges() throws {
        let decoded = try JSONDecoder().decode(
            MeetingSettings.self, from: Data(#"{"vaultPath":"~/notes"}"#.utf8))
        #expect(decoded.vaultPath == "~/notes")
    }

    @Test func roundTripsThroughStore() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        var settings = MeetingSettings()
        settings.transcriptionGlossary = "온프레미스, 페이로드"
        settings.liveTranscription = false
        try await store.upsert(.setting, settings)
        let loaded = await store.fetch(.setting, id: settings.id, as: MeetingSettings.self)
        #expect(loaded == settings)
    }

    @Test func ignoresForeignKeys() throws {
        let json = """
        {"hostRepoPath":"/x","repos":[],"transcriptionLanguage":"en","boostInputVolume":false}
        """
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data(json.utf8))
        #expect(decoded.transcriptionLanguage == "en")
        #expect(!decoded.boostInputVolume)
        #expect(decoded.liveTranscription)
    }
}

@Suite struct MeetingHostProfileTests {
    @Test func derivesPathsFromAppSupportName() {
        let base = URL(fileURLWithPath: "/tmp/support")
        let profile = MeetingHostProfile(appSupportName: "host", displayName: "host", base: base)
        #expect(profile.paths.supportDirectory.path == "/tmp/support/host")
        #expect(profile.paths.recordings.path == "/tmp/support/host/recordings")
        #expect(profile.paths.models.path == "/tmp/support/host/models")
        #expect(profile.paths.diarization.path == "/tmp/support/host/diarization")
        #expect(profile.paths.database.path == "/tmp/support/host/host.sqlite3")
        #expect(profile.audioTapName == "host-system-audio")
    }

    @Test func standaloneDiarizationRootMatchesScriptDefault() throws {
        let script = try String(contentsOf: #require(DiarizationSetup.bundledScriptURL), encoding: .utf8)
        #expect(script.contains("~/Library/Application Support/meeting/diarization"))
        let profile = MeetingHostProfile(appSupportName: "meeting", displayName: "meeting")
        #expect(profile.paths.diarization.path.hasSuffix("/Library/Application Support/meeting/diarization"))
    }
}

@Suite struct MeetingAssemblySettingsTests {
    private func services(claude: String, vault: String) async throws -> MeetingServices {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-assembly-\(UUID().uuidString)")
        var settings = MeetingSettings()
        settings.claudeExecutable = claude
        settings.vaultPath = vault
        return MeetingAssembly.assemble(
            settings: settings,
            profile: MeetingHostProfile(appSupportName: "meeting-test",
                                        displayName: "meeting", base: base),
            store: try SQLiteMeetingStore.inMemory(),
            notifier: SilentMeetingNotifier(),
            transcriber: FakeTranscriber(), live: nil)
    }

    @Test func skipsSummarizerWhenExecutableIsBlank() async throws {
        let off = try await services(claude: "   ", vault: "")
        #expect(off.summaryNotice != nil, "요약을 건너뛴다는 사실을 사람에게 말해야 한다")

        let on = try await services(claude: "claude", vault: "")
        #expect(on.summaryNotice == nil)
    }

    @Test func summarizesMatchesWhetherAssemblyPlugsSummarizer() async throws {
        var settings = MeetingSettings()
        for blank in ["", "   ", "\n\t "] {
            settings.claudeExecutable = blank
            #expect(settings.summarizes == false)
            #expect(try await services(claude: blank, vault: "").summaryNotice != nil)
        }
        settings.claudeExecutable = "claude"
        #expect(settings.summarizes)
        #expect(try await services(claude: "claude", vault: "").summaryNotice == nil)
    }

    @Test func staysQuietWhenVaultPathIsIntentionallyEmpty() async throws {
        #expect(try await services(claude: "claude", vault: "").vaultNotice == nil)
        #expect(try await services(claude: "claude", vault: "~/없는-경로-xyz").vaultNotice != nil)
    }
}
