import SwiftUI
import AVFoundation
import MeetingCore
import MeetingUI
import MinimalUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: MeetingSession

    @State private var justSaved = false
    @State private var model = ModelState.absent
    @State private var preparingModel = false
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MNSpacing.s16) {
                    MeetingSettingsForm(settings: $appState.settings)
                    summary
                    note
                    readiness
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(MNSpacing.s20)
                .frame(maxWidth: .infinity)
            }
            Divider()
            saveBar
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(MNColor.bg200)
        .task { refreshReadiness() }
        .onChange(of: appState.settings) { justSaved = false }
    }

    private var summary: some View {
        MNFormSection("요약") {
            MNFormRow("claude 경로",
                      hint: appState.settings.summarizes
                          ? "전사 텍스트가 Anthropic으로 전송됩니다."
                          : "비어 있어 녹음·전사까지만 만듭니다.",
                      help: "요약은 로컬 claude CLI에 전사를 넘겨 받아옵니다."
                          + " 비워 두면 요약 단계를 건너뛰고, 미팅은 그래도 정상 완료됩니다.") {
                MNTextField("claude", text: $appState.settings.claudeExecutable)
            }
        }
    }

    private var note: some View {
        MNFormSection("노트") {
            MNFormRow("저장 경로", hint: vaultHint,
                      help: "요약을 마크다운 노트로 내보냅니다."
                          + " 비워 두면 요약이 앱 안에만 남습니다.") {
                MNTextField("비우면 저장하지 않음", text: $appState.settings.vaultPath)
            }
        }
    }

    private var vaultHint: String {
        guard !appState.settings.vaultPath
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "노트를 파일로 내보내지 않습니다 — 요약은 앱 안에만 남습니다."
        }
        guard let root = MeetingAssembly.resolveVaultRoot(appState.settings.vaultPath) else {
            return "vault를 찾지 못했습니다 — 경로에 wiki/ 폴더가 있어야 합니다."
        }
        let fm = FileManager.default
        let missing = ["raw/", "wiki/log.md", "wikimap.py"].filter {
            !fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else { return root.path }
        return "\(root.path) — \(missing.joined(separator: ", "))이(가) 없습니다."
    }

    private enum ModelState { case absent, present, verified, failed }

    private var readiness: some View {
        MNFormSection("준비 상태") {
            MNStatusRow(model == .absent ? .missing : (model == .failed ? .problem : .ready),
                        label: "전사 모델", status: modelStatus,
                        help: "WhisperKit large-v3(약 626MB)를 미리 내려받아 둡니다."
                            + " 받아 두지 않으면 첫 전사가 내려받기부터 시작해 수십 초 걸립니다.") {
                if model == .absent || model == .failed {
                    Button(preparingModel ? "준비 중…" : "준비") { prepareModel() }
                        .buttonStyle(MNOutlineButtonStyle())
                        .disabled(preparingModel)
                }
            }
            MNStatusRow(micLevel, label: "마이크 권한", status: micStatus,
                        help: "거부돼 있으면 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서"
                            + " meeting을 켜 주십시오.") {
                if mic == .notDetermined {
                    Button("허용 요청") { requestMicrophone() }
                        .buttonStyle(MNOutlineButtonStyle())
                }
            }
            MNStatusRow(.unknown, label: "시스템 오디오", status: "첫 녹음에서 묻습니다",
                        help: "상대 목소리는 시스템 오디오에서 받습니다."
                            + " 거부하면 내 마이크만 녹음됩니다.")
            MeetingDiarizationRow(setup: session.diarization)
        }
    }

    private var modelStatus: String {
        switch model {
        case .absent: "받지 않음"
        case .present: "받아 둠"
        case .verified: "준비됨"
        case .failed: "적재하지 못했습니다 — 네트워크를 확인해 주십시오."
        }
    }

    private var micLevel: MNStatusLevel {
        switch mic {
        case .authorized: .ready
        case .notDetermined: .unknown
        default: .problem
        }
    }

    private var micStatus: String {
        switch mic {
        case .authorized: "허용됨"
        case .notDetermined: "아직 묻지 않았습니다"
        default: "거부됨 — 녹음에 내 목소리가 담기지 않습니다"
        }
    }

    private var saveBar: some View {
        HStack(spacing: MNSpacing.s12) {
            if session.isRecording {
                Text("녹음 중에는 설정이 다음 저장 때 반영됩니다.")
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
            }
            Spacer()
            Button(justSaved ? "저장됨" : "저장") {
                Task {
                    await appState.saveSettings()
                    justSaved = true
                    refreshReadiness()
                }
            }
            .buttonStyle(MNSolidButtonStyle())
            .disabled(!appState.isDirty)
        }
        .padding(.horizontal, MNSpacing.s20)
        .padding(.vertical, MNSpacing.s12)
        .background(MNColor.bg100)
    }

    private func refreshReadiness() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if model != .verified {
            model = session.modelReady ? .present : .absent
        }
    }

    private func prepareModel() {
        Task {
            preparingModel = true
            model = await session.services?.warmUp() ?? false ? .verified : .failed
            preparingModel = false
        }
    }

    private func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }
}
