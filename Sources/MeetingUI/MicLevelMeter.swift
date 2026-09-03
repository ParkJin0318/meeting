import SwiftUI
import MeetingCore

@MainActor
public final class MicLevelMeter: ObservableObject {
    public static let slots = 48

    @Published public private(set) var levels: [Float] = []

    private var task: Task<Void, Never>?

    public init() {}

    public func start(_ stream: AsyncStream<Float>) {
        task?.cancel()
        levels = Array(repeating: 0, count: Self.slots)
        task = Task { [weak self] in
            for await level in stream {
                guard let self, !Task.isCancelled else { return }
                if self.levels.count >= Self.slots { self.levels.removeFirst() }
                self.levels.append(level)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        levels = []
    }
}
