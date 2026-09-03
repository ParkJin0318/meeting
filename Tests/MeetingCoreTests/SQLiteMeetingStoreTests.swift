import Testing
import Foundation
@testable import MeetingCore

@Suite struct SQLiteMeetingStoreTests {
    @Test func mutateIsTestAndSet() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let meeting = Meeting(title: "회의")
        try await store.upsertMeeting(meeting)

        let renamed = try await store.mutateMeeting(id: meeting.id) { $0.title = "바뀐 회의"; return true }
        #expect(renamed?.title == "바뀐 회의")
        let untouched = try await store.mutateMeeting(id: meeting.id) { _ in false }
        #expect(untouched == nil)
        let missing = try await store.mutateMeeting(id: "없는-id") { _ in true }
        #expect(missing == nil, "없는 행은 되살리지 않는다")
        #expect(await store.meeting(id: meeting.id)?.title == "바뀐 회의")
    }

    @Test func stampsChangeOnEveryWriteAndDelete() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let meeting = Meeting(title: "aaaa")
        try await store.upsertMeeting(meeting)
        let first = await store.meetingStamps()[meeting.id]
        try await store.mutateMeeting(id: meeting.id) { $0.title = "bbbb"; return true }
        let second = await store.meetingStamps()[meeting.id]
        #expect(first != second)

        try await store.deleteMeeting(id: meeting.id)
        #expect(await store.meetingStamps()[meeting.id] == nil, "삭제된 id는 집합에서 빠진다")
        #expect(await store.allMeetings().isEmpty)
    }

    @Test func readsRowsWithVerbatimKeys() async throws {
        let store = try SQLiteMeetingStore.inMemory()
        let meeting = Meeting(title: "키 확인", scheduledAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.upsert(.meeting, meeting)
        let data = try JSONEncoder().encode(meeting)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == meeting.id)
        #expect(object["title"] as? String == "키 확인")
        #expect(object["status"] as? String == "scheduled")
        #expect(SQLiteMeetingStore.EntityKind.meeting.rawValue == "meeting")
    }
}
