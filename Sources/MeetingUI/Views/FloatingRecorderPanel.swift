import SwiftUI
import AppKit
import Combine
import MeetingCore
import MinimalUI

final class FloatingRecorderPanel: NSPanel {
    init(content: NSView, size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                              .ignoresCycle]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
}

@MainActor
public final class FloatingRecorderController {
    private static let originKey = "floating-recorder-origin"

    private enum Mode: Equatable {
        case hidden, detected
        case recording(live: Bool)

        var size: CGSize? {
            switch self {
            case .hidden: nil
            case .detected: FloatingRecorderView.detectedSize
            case .recording(let live):
                live ? FloatingRecorderView.recordingLiveSize : FloatingRecorderView.recordingSize
            }
        }
    }

    private var panel: FloatingRecorderPanel?
    private var moveObserver: NSObjectProtocol?
    private var visibility: AnyCancellable?

    public init() {}

    public func attach(to session: MeetingSession) {
        guard visibility == nil else { return }
        visibility = session.objectWillChange
            .receive(on: RunLoop.main)
            .map { [weak session] _ in session.map(Self.mode(of:)) ?? .hidden }
            .prepend(Self.mode(of: session))
            .removeDuplicates()
            .sink { [weak self, weak session] mode in
                MainActor.assumeIsolated {
                    guard let self, let session else { return }
                    if let size = mode.size {
                        self.show(AnyView(FloatingRecorderView().environmentObject(session)),
                                  size: size)
                    } else {
                        self.hide()
                    }
                }
            }
    }

    private static func mode(of session: MeetingSession) -> Mode {
        guard session.showsRecorderWidget else { return .hidden }
        return session.isRecording ? .recording(live: session.showsLiveLine) : .detected
    }

    private func show(_ content: AnyView, size: CGSize) {
        if let panel {
            (panel.contentView as? NSHostingView<AnyView>)?.rootView = content
            resize(panel, to: size)
            return
        }
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = FloatingRecorderPanel(content: hosting, size: size)
        panel.setFrameOrigin(savedOrigin(for: panel))
        panel.orderFrontRegardless()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let origin = panel?.frame.origin else { return }
                UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: Self.originKey)
            }
        }
        self.panel = panel
    }

    private func resize(_ panel: FloatingRecorderPanel, to size: CGSize) {
        let frame = panel.frame
        guard frame.size != size else { return }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                              y: frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
        panel.invalidateShadow()
    }

    private func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func savedOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let fallback = NSPoint(x: screen.maxX - panel.frame.width - 24,
                               y: screen.minY + 24)
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.originKey),
              let x = stored["x"] as? CGFloat, let y = stored["y"] as? CGFloat else {
            return fallback
        }
        let point = NSPoint(x: x, y: y)
        let visible = NSScreen.screens.contains { $0.visibleFrame.contains(point) }
        return visible ? point : fallback
    }
}

struct FloatingRecorderView: View {
    nonisolated static let recordingSize = CGSize(width: 232, height: 44)
    nonisolated static let recordingLiveSize = CGSize(width: 380, height: 72)
    nonisolated static let detectedSize = CGSize(width: 344, height: 44)

    @EnvironmentObject private var session: MeetingSession

    private var showsLiveLine: Bool { session.isRecording && session.showsLiveLine }

    var body: some View {
        Group {
            if session.isRecording {
                recording
            } else if let call = session.pendingCall {
                detected(call)
            }
        }
        .padding(.horizontal, MNSpacing.s12)
        .padding(.vertical, showsLiveLine ? MNSpacing.s8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(MNColor.divider.opacity(0.5), lineWidth: 1))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsLiveLine
                         ? MNRadius.r12 : Self.recordingSize.height / 2)
    }

    @ViewBuilder
    private var recording: some View {
        if showsLiveLine {
            VStack(alignment: .leading, spacing: MNSpacing.s4) {
                controls
                LiveLine(store: session.liveTranscript)
            }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: MNSpacing.s8) {
            RecordingPulse()
            if let meeting = session.recordingMeeting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MNDateFormat.timer(from: meeting.startedAt ?? meeting.scheduledAt,
                                            to: context.date))
                        .font(MNFont.caption1.monospacedDigit())
                        .foregroundStyle(MNColor.contents000)
                }
                .fixedSize()
            } else {
                Text("준비 중")
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
            }
            Spacer(minLength: 0)
            WaveformBars(meter: session.micMeter, height: 18, barWidth: 2, maxBars: 16)
            Spacer(minLength: 0)
            PillIconButton(systemName: "stop.fill", label: "녹음 종료",
                           foreground: MNColor.fixedWhite, background: MNColor.roleRed) {
                Task { await session.stopRecording() }
            }
        }
    }

    private func detected(_ call: CallDetection) -> some View {
        HStack(spacing: MNSpacing.s8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MNColor.secondary)
            Text(call.suggestedTitle)
                .font(MNFont.caption1)
                .foregroundStyle(MNColor.contents000)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("녹음") {
                Task { await session.startRecording(call: call) }
            }
            .buttonStyle(MNPillButtonStyle())
            PillIconButton(systemName: "xmark", label: "이번 통화는 무시") {
                session.dismissDetectedCall()
            }
        }
    }
}

private struct LiveLine: View {
    @ObservedObject var store: LiveTranscriptStore

    var body: some View {
        Text(store.latestLine ?? store.notice ?? "듣고 있습니다.")
            .font(MNFont.caption1)
            .foregroundStyle(store.latestLine == nil
                             ? MNColor.contents150 : MNColor.contents100)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MNPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MNFont.caption1)
            .foregroundStyle(MNColor.contents999)
            .padding(.horizontal, MNSpacing.s12)
            .frame(height: 26)
            .background(MNColor.primary, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PillIconButton: View {
    let systemName: String
    let label: String
    var foreground: Color = MNColor.contents150
    var background: Color = .clear
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct RecordingPulse: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(MNColor.roleRed)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

struct WaveformBars: View {
    @ObservedObject var meter: MicLevelMeter
    var height: CGFloat = 64
    var barWidth: CGFloat = 3
    var maxBars: Int?

    private var levels: [Float] {
        guard let maxBars else { return meter.levels }
        return Array(meter.levels.suffix(maxBars))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(MNColor.secondary)
                    .frame(width: barWidth, height: max(2, CGFloat(level) * height))
            }
        }
        .frame(height: height)
    }
}
