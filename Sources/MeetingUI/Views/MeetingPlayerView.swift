import SwiftUI
@preconcurrency import AVFoundation
import MinimalUI

@MainActor
final class MeetingPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedPath: String?

    init(url: URL?) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
        load(url: url)
    }

    func load(url: URL?) {
        guard url?.path != loadedPath else { return }
        loadedPath = url?.path
        currentTime = 0
        duration = 0
        isPlaying = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.currentTime = 0
                self?.isPlaying = false
            }
        }
        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            guard let self, self.loadedPath == url.path else { return }
            self.duration = seconds.isFinite ? seconds : 0
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    func teardown() {
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

struct MeetingPlayerView: View {
    @ObservedObject var controller: MeetingPlayerController
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        HStack(spacing: MNSpacing.s12) {
            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(MNColor.contents000)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isPlaying ? "일시정지" : "재생")

            Text(timeText(isScrubbing ? scrubTime : controller.currentTime))
                .font(MNFont.caption1.monospacedDigit())
                .foregroundStyle(MNColor.contents150)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime
                        : min(controller.currentTime, controller.duration) },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(controller.duration, 0.01)
            ) { editing in
                if editing {
                    scrubTime = controller.currentTime
                    isScrubbing = true
                } else {
                    controller.seek(to: scrubTime)
                    isScrubbing = false
                }
            }
            .tint(MNColor.secondary)

            Text(timeText(controller.duration))
                .font(MNFont.caption1.monospacedDigit())
                .foregroundStyle(MNColor.contents150)
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
