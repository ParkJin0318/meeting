import Foundation
import UserNotifications
import MeetingCore
import MeetingUI

@MainActor
final class AppNotifier {
    func requestPermission() async {
        guard isBundled else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge])
    }

    func notice(_ message: String) {
        post(id: "notice-\(UUID().uuidString)", title: "미팅", body: message)
    }

    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    private func post(id: String, title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

final class AppNotificationSink: MeetingNotifying, @unchecked Sendable {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func notice(message: String) async {
        await MainActor.run { [weak appState] in
            appState?.notifier.notice(message)
        }
        await appState?.meetings.reload()
    }
}
