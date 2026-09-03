import SwiftUI
import AppKit
import MeetingCore
import MeetingUI

@MainActor
final class AppState: ObservableObject {
    static let profile = MeetingHostProfile(appSupportName: "meeting", displayName: "meeting")

    let meetings = MeetingSession()
    let notifier = AppNotifier()
    @Published var settings = MeetingSettings()
    @Published var bootstrapped = false
    @Published var statusMessage = ""

    private var store: SQLiteMeetingStore?
    private var persisted = MeetingSettings()

    var isDirty: Bool { settings != persisted }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        meetings.openNote = { meeting in
            guard let path = meeting.vaultNotePath else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        do {
            let store = try SQLiteMeetingStore(path: Self.profile.paths.database)
            self.store = store
            settings = await store.fetch(.setting, id: MeetingSettings().id, as: MeetingSettings.self)
                ?? CoreAssembly.defaultSettings()
            persisted = settings
            assemble(store: store)
            await meetings.bootstrap()
            await notifier.requestPermission()
        } catch {
            bootstrapped = false
            statusMessage = "저장소를 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func assemble(store: SQLiteMeetingStore) {
        let services = CoreAssembly.assemble(
            settings: settings, profile: Self.profile, store: store,
            notifier: AppNotificationSink(appState: self))
        meetings.install(services)
        statusMessage = services.vaultNotice ?? ""
    }

    func saveSettings() async {
        guard let store else { return }
        try? await store.upsert(.setting, settings)
        persisted = settings
        if !meetings.isRecording {
            assemble(store: store)
        }
        await meetings.reload()
    }
}
