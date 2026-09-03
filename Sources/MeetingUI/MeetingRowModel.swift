import Foundation
import MeetingCore

struct MeetingRowModel: Identifiable, Equatable {
    let id: String
    let title: String
    let status: Meeting.Status
    let metaText: String
    let preview: String?

    init(meeting: Meeting, dateText: String) {
        id = meeting.id
        title = meeting.title
        status = meeting.status
        var parts = [dateText]
        if let duration = MeetingDocument.durationText(meeting) { parts.append(duration) }
        let speakers = Set(meeting.segments.compactMap(\.speaker)).count
        if speakers > 0 { parts.append("화자 \(speakers)") }
        metaText = parts.joined(separator: " · ")
        preview = meeting.summaryPreview
    }
}
