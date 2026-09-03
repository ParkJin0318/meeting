import SwiftUI
import AppKit
import MeetingCore
import MeetingUI
import MinimalUI

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MeetingApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor private var appDelegate: MeetingAppDelegate
    @State private var recorderPanel = FloatingRecorderController()

    var body: some Scene {
        WindowGroup("meeting") {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.meetings)
                .tint(MNColor.secondary)
                .task { await appState.bootstrap() }
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    recorderPanel.attach(to: appState.meetings)
                }
        }
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.meetings)
                .tint(MNColor.secondary)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: MeetingSession

    private var notice: String {
        [appState.statusMessage, session.modelStatus ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if !notice.isEmpty {
                MNNoticeBar(kind: .info, message: notice) {
                    SettingsLink {
                        Text("설정")
                    }
                    .buttonStyle(MNOutlineButtonStyle())
                }
                .padding(MNSpacing.s12)
            }
            MeetingsView()
        }
        .background(MNColor.bg100)
    }
}
