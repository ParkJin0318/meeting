import SwiftUI
import MeetingCore
import MinimalUI

struct MeetingTranscriptView: View {
    let meeting: Meeting
    @ObservedObject var player: MeetingPlayerController
    @Binding var jumpTarget: TimeInterval?
    @EnvironmentObject private var session: MeetingSession

    @State private var query = ""
    @State private var editingSpeakers = false
    @State private var rows: [Row] = []
    @State private var filtered: [Row] = []
    @State private var lines: [Line] = []
    @State private var labels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            controls
            if let note = meeting.diarizationNote {
                Text("화자 구분을 건너뛰었습니다: \(note)")
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
            }
            if let note = meeting.coverage?.note {
                Text(note)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.roleRed)
            }
            if !meeting.speakerNameSuggestions.isEmpty {
                speakerSuggestions
            }
            if editingSpeakers, !labels.isEmpty {
                speakerEditor
            }
            transcriptList
        }
        .onChange(of: meeting.segments) { _, _ in rebuild() }
        .onChange(of: meeting.transcript) { _, _ in rebuild() }
        .onChange(of: query) { _, _ in applyQuery() }
        .onAppear { rebuild() }
    }

    private var controls: some View {
        HStack(spacing: MNSpacing.s8) {
            MNTextField("전사 검색", text: $query, font: MNFont.body3)
                .frame(maxWidth: 260)
            if !labels.isEmpty {
                Button(editingSpeakers ? "이름 편집 닫기" : "화자 이름") {
                    editingSpeakers.toggle()
                }
                .buttonStyle(MNOutlineButtonStyle())
                .help("자동 라벨에 참석자 이름을 붙입니다.")
            }
            Spacer()
            Text("\(filtered.count)줄")
                .font(MNFont.caption1)
                .foregroundStyle(MNColor.contents150)
        }
    }

    private var speakerSuggestions: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            Text("요약이 화자 이름을 짚었습니다")
                .font(MNFont.body3)
                .foregroundStyle(MNColor.contents200)
            ForEach(suggestedLabels, id: \.self) { label in
                HStack(spacing: MNSpacing.s8) {
                    Text(label)
                        .font(MNFont.caption1)
                        .foregroundStyle(Self.color(for: label))
                        .frame(width: 72, alignment: .leading)
                    Text("→ \(meeting.speakerNameSuggestions[label] ?? "")")
                        .font(MNFont.body3)
                        .foregroundStyle(MNColor.contents100)
                }
            }
            HStack(spacing: MNSpacing.s8) {
                Button("전부 적용") {
                    Task { await session.applySpeakerSuggestions(meetingID: meeting.id) }
                }
                .buttonStyle(MNSolidButtonStyle())
                Button("무시") {
                    Task { await session.dismissSpeakerSuggestions(meetingID: meeting.id) }
                }
                .buttonStyle(MNOutlineButtonStyle())
                Text("이름은 전사·요약·위키 노트에 함께 반영됩니다.")
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
            }
        }
        .padding(MNSpacing.s12)
        .background(MNColor.bg300, in: RoundedRectangle(cornerRadius: MNRadius.r8))
    }

    private var suggestedLabels: [String] {
        let suggested = meeting.speakerNameSuggestions
        let ordered = labels.filter { suggested[$0] != nil }
        let rest = suggested.keys.filter { !labels.contains($0) }.sorted()
        return ordered + rest
    }

    private var speakerEditor: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            ForEach(labels, id: \.self) { label in
                SpeakerNameRow(
                    label: label,
                    name: meeting.speakerNames[label] ?? "",
                    suggestion: meeting.speakerNameSuggestions[label],
                    color: Self.color(for: label)
                ) { name in
                    Task {
                        await session.renameSpeaker(meetingID: meeting.id,
                                                      label: label, name: name)
                    }
                }
            }
            Text("비워 두면 자동 라벨로 되돌아갑니다. 이름은 요약에도 그대로 쓰입니다.")
                .font(MNFont.caption1)
                .foregroundStyle(MNColor.contents150)
        }
        .padding(MNSpacing.s12)
        .background(MNColor.bg300, in: RoundedRectangle(cornerRadius: MNRadius.r8))
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.id) { line in
                        switch line {
                        case let .spoken(row):
                            TranscriptRow(
                                segment: row.segment,
                                speakerName: row.segment.speaker.map(meeting.displayName(for:)),
                                speakerColor: row.segment.speaker.map(Self.color(for:)),
                                isPlaying: row.index == playingIndex
                            ) {
                                player.seek(to: row.segment.start)
                            }
                            .id(row.index)
                        case let .missing(gap, id):
                            MissingRangeRow(gap: gap) { player.seek(to: gap.start) }
                                .id(id)
                        }
                    }
                }
                .padding(.vertical, MNSpacing.s4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MNColor.bg300, in: RoundedRectangle(cornerRadius: MNRadius.r8))
            .onChange(of: playingIndex) { _, index in
                guard let index, player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                query = ""
                applyQuery()
                guard let row = rows.last(where: { $0.segment.isSeekable
                    && $0.segment.start <= target + 0.5 }) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(row.index, anchor: .center)
                }
                jumpTarget = nil
            }
        }
    }

    private struct Row: Equatable {
        let index: Int
        let segment: TranscriptSegment
    }

    private enum Line: Equatable {
        case spoken(Row)
        case missing(TranscriptCoverage.Gap, id: Int)

        var id: Int {
            switch self {
            case let .spoken(row): row.index
            case let .missing(_, id): id
            }
        }
    }

    private func rebuild() {
        let segments = meeting.displaySegments
        rows = segments.enumerated().map { Row(index: $0.offset, segment: $0.element) }
        var seen: Set<String> = []
        labels = segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
        applyQuery()
    }

    private func applyQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            filtered = rows
            lines = interleaved(rows)
            return
        }
        filtered = rows.filter { row in
            if row.segment.text.localizedStandardContains(trimmed) { return true }
            guard let speaker = row.segment.speaker else { return false }
            return meeting.displayName(for: speaker).localizedStandardContains(trimmed)
        }
        lines = filtered.map(Line.spoken)
    }

    private func interleaved(_ rows: [Row]) -> [Line] {
        let gaps = meeting.coverage?.gaps ?? []
        guard !gaps.isEmpty else { return rows.map(Line.spoken) }
        var pending = gaps.enumerated().map { (id: -($0.offset + 1), gap: $0.element) }
        var result: [Line] = []
        for row in rows {
            while let next = pending.first, next.gap.start <= row.segment.start {
                result.append(.missing(next.gap, id: next.id))
                pending.removeFirst()
            }
            result.append(.spoken(row))
        }
        result.append(contentsOf: pending.map { Line.missing($0.gap, id: $0.id) })
        return result
    }

    private var playingIndex: Int? {
        let time = player.currentTime
        return rows.last { $0.segment.isSeekable && $0.segment.start <= time }?.index
    }

    static func color(for label: String) -> Color { MNColor.identity(for: label) }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let speakerName: String?
    let speakerColor: Color?
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MNSpacing.s8) {
            Text(timeText)
                .font(MNFont.caption1.monospacedDigit())
                .foregroundStyle(MNColor.contents200)
                .frame(width: 44, alignment: .leading)
            if let speakerName, let speakerColor {
                Text(speakerName)
                    .font(MNFont.caption1)
                    .foregroundStyle(speakerColor)
                    .lineLimit(1)
                    .frame(width: 72, alignment: .leading)
            }
            Text(segment.text)
                .font(.system(size: 12))
                .foregroundStyle(MNColor.contents100)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, MNSpacing.s4)
        .padding(.horizontal, MNSpacing.s12)
        .background(MNColor.secondary.opacity(isPlaying ? 0.16 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if segment.isSeekable { onTap() } }
        .help(segment.isSeekable ? "이 시점부터 재생합니다." : "")
    }

    private var timeText: String {
        guard segment.isSeekable else { return "--:--" }
        let total = Int(segment.start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct MissingRangeRow: View {
    let gap: TranscriptCoverage.Gap
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: MNSpacing.s8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(MNColor.roleRed)
                .frame(width: 44, alignment: .leading)
            Text(gap.label)
                .font(MNFont.caption1)
                .foregroundStyle(MNColor.roleRed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, MNSpacing.s4)
        .padding(.horizontal, MNSpacing.s12)
        .background(MNColor.roleRed.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .help("이 구간은 전사가 비었습니다. 눌러 그 시점부터 재생해 확인하십시오.")
    }
}

private struct SpeakerNameRow: View {
    let label: String
    let name: String
    let suggestion: String?
    let color: Color
    let onCommit: (String) -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: MNSpacing.s8) {
            Text(label)
                .font(MNFont.caption1)
                .foregroundStyle(color)
                .frame(width: 72, alignment: .leading)
            MNTextField(placeholder, text: $draft, font: MNFont.body3)
                .onSubmit { onCommit(draft) }
            Button("저장") { onCommit(draft) }
                .buttonStyle(MNSolidButtonStyle())
        }
        .onAppear { draft = name }
    }

    private var placeholder: String {
        guard let suggestion, !suggestion.isEmpty else { return "참석자 이름" }
        return "참석자 이름 (제안: \(suggestion))"
    }
}
