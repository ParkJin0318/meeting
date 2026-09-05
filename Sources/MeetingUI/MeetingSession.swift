import SwiftUI
import MeetingCore

@MainActor
public final class MeetingSession: ObservableObject {
    @Published public private(set) var meetings: [Meeting] = []
    @Published public private(set) var isRecording = false
    /// 일시 중지 장부의 미러. 바뀌는 건 누르는 순간뿐이라 프레임 값이 아니다.
    @Published public private(set) var recordingPause = RecordingPause()
    @Published public private(set) var detectedCall: CallDetection?
    @Published public private(set) var dismissedCall: CallDetection?
    @Published public private(set) var modelStatus: String?

    public let micMeter = MicLevelMeter()
    public let liveTranscript = LiveTranscriptStore()

    public var openNote: ((Meeting) -> Void)?
    public var vaultDidChange: (() async -> Void)?

    public private(set) var services: MeetingServices?
    private var callDetectionTask: Task<Void, Never>?

    public init() {}

    public var showsLiveLine: Bool { services?.live != nil }

    public var isPaused: Bool { recordingPause.isPaused }

    public var recordingMeeting: Meeting? {
        meetings.first { $0.status == .recording }
    }

    public var pendingCall: CallDetection? {
        guard !isRecording, let detectedCall, detectedCall != dismissedCall else { return nil }
        return detectedCall
    }

    public var showsRecorderWidget: Bool {
        isRecording || pendingCall != nil
    }

    public var vaultNotice: String? { services?.vaultNotice }

    public var diarization: DiarizationSetup? { services?.diarization }
    public var modelReady: Bool { services?.modelReady() ?? false }

    public func install(_ services: MeetingServices) {
        self.services = services
        subscribeCallDetections(services.callDetector)
        warmUpModel(services)
    }

    private var warmUpTask: Task<Void, Never>?

    private func warmUpModel(_ services: MeetingServices) {
        warmUpTask?.cancel()
        modelStatus = "전사 모델을 준비하는 중입니다. 첫 실행은 내려받기와 컴파일로 수 분 걸립니다."
        warmUpTask = Task { @MainActor [weak self] in
            let ready = await services.warmUp()
            guard let self, !Task.isCancelled else { return }
            self.modelStatus = ready
                ? nil
                : "전사 모델을 적재하지 못했습니다. 네트워크를 확인하고 설정의 [모델 준비]를 눌러 주십시오."
        }
    }

    public func bootstrap() async {
        guard let services else { return }
        await services.center.recoverInterruptedMeetings()
        await services.center.backfillTranscriptSegments()
        await reload()
    }

    public func reload() async {
        guard let services else { return }
        let latest = await services.center.meetings()
        if latest != meetings { meetings = latest }
        let recording = await services.center.isRecording
        if recording != isRecording { isRecording = recording }
        let pause = await services.center.recordingPause
        if pause != recordingPause { recordingPause = pause }
    }

    private func subscribeCallDetections(_ detector: CallDetector) {
        callDetectionTask?.cancel()
        detectedCall = nil
        dismissedCall = nil
        callDetectionTask = Task { @MainActor [weak self] in
            for await detection in await detector.detections() {
                guard let self, !Task.isCancelled else { return }
                self.detectedCall = detection
                if detection == nil { self.dismissedCall = nil }
                if detection != nil, let live = self.services?.live {
                    Task.detached(priority: .utility) { await live.prewarm() }
                }
            }
        }
    }

    @discardableResult
    public func startRecording(call: CallDetection? = nil) async -> String? {
        guard let services, !isRecording else { return nil }
        isRecording = true
        await services.callDetector.setSuppressed(true)
        detectedCall = nil
        let title = call?.suggestedTitle ?? "미팅 \(MNDateFormatShim.dayTime(Date()))"
        guard let meeting = try? await services.center.startAdhocRecording(
            title: title, origin: call?.origin) else {
            await services.callDetector.setSuppressed(false)
            await reload()
            return nil
        }
        subscribeMicLevels()
        await reload()
        return meeting.id
    }

    public func dismissDetectedCall() {
        dismissedCall = detectedCall
    }

    private func subscribeMicLevels() {
        guard let services else { return }
        micMeter.start(services.recorder.micLevels())
        if let live = services.live { liveTranscript.start(live.updates()) }
    }

    /// 미터·라이브 텍스트·통화 감지 억제는 그대로 둔다 — `stop()`은 화면을 비우고,
    /// 억제를 풀면 15초 뒤 감지 배너가 다시 떠 패널이 흔들린다.
    public func pauseRecording() async {
        guard let services, isRecording else { return }
        await services.center.pauseRecording()
        await reload()
    }

    public func resumeRecording() async {
        guard let services, isRecording else { return }
        await services.center.resumeRecording()
        await reload()
    }

    public func togglePause() async {
        if isPaused { await resumeRecording() } else { await pauseRecording() }
    }

    public func stopRecording() async {
        guard let services else { return }
        micMeter.stop()
        liveTranscript.stop()
        guard let finished = try? await services.center.finishRecording() else {
            await services.callDetector.setSuppressed(false)
            await reload()
            return
        }
        await services.callDetector.setSuppressed(false)
        await reload()
        _ = try? await services.center.processRecording(finished)
        await reload()
        await vaultDidChange?()
    }

    public func renameSpeaker(meetingID: String, label: String, name: String) async {
        guard let center = services?.center else { return }
        try? await center.renameSpeaker(meetingID: meetingID, label: label, name: name)
        await reload()
    }

    public func applySpeakerSuggestions(meetingID: String) async {
        guard let center = services?.center else { return }
        try? await center.applySpeakerSuggestions(meetingID: meetingID)
        await reload()
    }

    public func dismissSpeakerSuggestions(meetingID: String) async {
        guard let center = services?.center else { return }
        try? await center.dismissSpeakerSuggestions(meetingID: meetingID)
        await reload()
    }

    public func renameMeeting(id: String, title: String) async {
        guard let center = services?.center else { return }
        try? await center.renameMeeting(id: id, title: title)
        await reload()
        await vaultDidChange?()
    }

    public func deleteMeeting(id: String) async {
        guard let center = services?.center else { return }
        try? await center.deleteMeeting(id: id)
        await reload()
        await vaultDidChange?()
    }

    public func reprocessMeeting(id: String, summaryOnly: Bool? = nil) async {
        guard let center = services?.center,
              let prepared = try? await center.prepareReprocess(
                  meetingID: id, summaryOnly: summaryOnly) else {
            return
        }
        await reload()
        _ = try? await center.processRecording(prepared)
        await reload()
        await vaultDidChange?()
    }
}
