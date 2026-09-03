import Foundation

public struct MeetingSummary: Sendable, Equatable {
    public let summary: String
    public let speakers: [String: String]

    public init(summary: String, speakers: [String: String] = [:]) {
        self.summary = summary
        self.speakers = speakers
    }
}

public protocol MeetingSummarizing: Sendable {
    func summarize(prompt: String, title: String) async throws -> MeetingSummary
}
