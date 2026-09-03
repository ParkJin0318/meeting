import Foundation

public protocol MeetingStoring: Sendable {
    func meeting(id: String) async -> Meeting?
    func allMeetings() async -> [Meeting]
    func upsertMeeting(_ meeting: Meeting) async throws
    @discardableResult
    func mutateMeeting(id: String,
                       _ apply: @Sendable (inout Meeting) -> Bool) async throws -> Meeting?
    func deleteMeeting(id: String) async throws
    func meetingStamps() async -> [String: String]
}
