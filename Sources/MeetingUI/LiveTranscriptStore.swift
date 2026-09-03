import SwiftUI
import MeetingCore

@MainActor
public final class LiveTranscriptStore: ObservableObject {
    @Published public private(set) var confirmed: [TranscriptSegment] = []
    @Published public private(set) var pending: String = ""
    @Published public private(set) var notice: String?

    private var task: Task<Void, Never>?

    public init() {}

    public var latestLine: String? {
        confirmed.last.map { segment in
            let speaker = segment.speaker.map { "\($0): " } ?? ""
            return speaker + segment.text
        }
    }

    public var isEmpty: Bool { confirmed.isEmpty && pending.isEmpty }

    public func start(_ stream: AsyncStream<LiveTranscriptUpdate>) {
        task?.cancel()
        confirmed = []
        pending = ""
        notice = nil
        task = Task { [weak self] in
            for await update in stream {
                guard let self, !Task.isCancelled else { return }
                self.confirmed = update.confirmed
                self.pending = update.pending
                self.notice = update.notice
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        confirmed = []
        pending = ""
        notice = nil
    }
}
