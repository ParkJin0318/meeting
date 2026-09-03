import SwiftUI
import MeetingCore
import MinimalUI

public struct MeetingsView: View {
    @EnvironmentObject private var session: MeetingSession
    @State private var selectedMeetingID: String?
    @State private var query = ""
    @State private var rows: [Row] = []

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 340)
            Divider()
            if let meeting = session.meetings.first(where: { $0.id == selectedMeetingID }) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("미팅을 선택해 주십시오.")
                    .font(MNFont.body3)
                    .foregroundStyle(MNColor.contents150)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MNColor.bg200)
            }
        }
    }

    private enum Row: Identifiable, Equatable {
        case header(id: String, title: String, isFirst: Bool)
        case meeting(MeetingRowModel)

        var id: String {
            switch self {
            case let .header(id, _, _): id
            case let .meeting(model): model.id
            }
        }
    }

    private func rebuild() {
        let filtered = MeetingList.filter(session.meetings, query: query)
        var out: [Row] = []
        var sawHeader = false
        for row in MeetingList.rows(filtered) {
            switch row {
            case let .header(title):
                out.append(.header(id: row.id, title: title, isFirst: !sawHeader))
                sawHeader = true
            case let .meeting(meeting):
                out.append(.meeting(MeetingRowModel(
                    meeting: meeting, dateText: MNDateFormat.dayTime(meeting.scheduledAt))))
            }
        }
        rows = out
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("미팅")
                    .font(MNFont.title1)
                    .foregroundStyle(MNColor.contents000)
                Spacer()
                if session.isRecording {
                    Button("녹음 종료") {
                        Task { await session.stopRecording() }
                    }
                    .buttonStyle(MNDangerButtonStyle())
                } else {
                    Button("녹음 시작") {
                        Task {
                            if let id = await session.startRecording() {
                                selectedMeetingID = id
                            }
                        }
                    }
                    .buttonStyle(MNSolidButtonStyle())
                }
            }
            .padding(.horizontal, MNSpacing.s20)
            .padding(.top, MNSpacing.s20)
            .padding(.bottom, MNSpacing.s12)

            MNTextField("제목·요약·전사 검색", text: $query, font: MNFont.body3)
                .padding(.horizontal, MNSpacing.s20)
                .padding(.bottom, MNSpacing.s12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case let .header(_, title, isFirst):
                            VStack(alignment: .leading, spacing: 0) {
                                if !isFirst {
                                    Rectangle()
                                        .fill(MNColor.dividerLite)
                                        .frame(height: 1)
                                        .padding(.horizontal, MNSpacing.s8)
                                }
                                Text(title)
                                    .font(MNFont.caption1)
                                    .foregroundStyle(MNColor.contents100)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, MNSpacing.s8)
                                    .padding(.top, isFirst ? MNSpacing.s8 : MNSpacing.s24)
                                    .padding(.bottom, MNSpacing.s8)
                            }
                        case let .meeting(model):
                            MeetingRow(model: model,
                                       isSelected: selectedMeetingID == model.id)
                                .id(model.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedMeetingID = model.id }
                        }
                    }
                    if rows.isEmpty, !query.isEmpty {
                        Text("검색 결과가 없습니다.")
                            .font(MNFont.caption1)
                            .foregroundStyle(MNColor.contents150)
                            .padding(MNSpacing.s12)
                    }
                }
                .padding(.horizontal, MNSpacing.s8)
            }
        }
        .background(MNColor.bg100)
        .onChange(of: session.meetings) { _, _ in rebuild() }
        .onChange(of: query) { _, _ in rebuild() }
        .onAppear { rebuild() }
    }
}

private struct MeetingRow: View {
    let model: MeetingRowModel
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s4) {
            Text(model.title)
                .font(MNFont.subtitle2)
                .foregroundStyle(isSelected ? MNColor.fixedWhite : MNColor.contents000)
                .lineLimit(1)
            HStack(spacing: MNSpacing.s4) {
                if model.status != .done {
                    MeetingStatusChip(status: model.status)
                }
                Text(model.metaText)
                    .font(MNFont.caption1)
                    .foregroundStyle(isSelected
                        ? MNColor.fixedWhite.opacity(0.85) : MNColor.contents150)
                    .lineLimit(1)
            }
            if let preview = model.preview {
                Text(preview)
                    .font(MNFont.caption1)
                    .foregroundStyle(isSelected
                        ? MNColor.fixedWhite.opacity(0.75) : MNColor.contents200)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, MNSpacing.s8)
        .padding(.horizontal, MNSpacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MNColor.secondary.opacity(isSelected ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: MNRadius.r8))
        .contentTransition(.interpolate)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

struct MeetingStatusChip: View {
    let status: Meeting.Status

    var body: some View {
        switch status {
        case .scheduled:
            MNChip(text: "예정", color: MNColor.contents150, background: MNColor.bg300)
        case .recording:
            MNChip(text: "녹음 중", color: MNColor.contents999, background: MNColor.secondary)
        case .transcribing, .summarizing:
            MNChip(text: "정리 중", color: MNColor.roleBlue, background: MNColor.bgRoleBlue)
        case .done:
            MNChip(text: "완료", color: MNColor.roleGreen, background: MNColor.bgRoleGreen)
        case .failed:
            MNChip(text: "실패", color: MNColor.roleRed, background: MNColor.bgRoleRed)
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var session: MeetingSession
    let meeting: Meeting
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var tab: Tab = .summary
    @State private var jumpTarget: TimeInterval?
    @StateObject private var player: MeetingPlayerController

    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "요약", transcript = "전사"
        var id: String { rawValue }
    }

    init(meeting: Meeting) {
        self.meeting = meeting
        _player = StateObject(wrappedValue: MeetingPlayerController(url: meeting.playbackURL()))
    }

    var body: some View {
        if meeting.status == .recording {
            MeetingRecordingView(meeting: meeting)
        } else {
            detail
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if meeting.playbackURL() != nil {
                Divider()
                MeetingPlayerView(controller: player)
                    .padding(.horizontal, MNSpacing.s20)
                    .padding(.vertical, MNSpacing.s12)
                    .background(MNColor.bg100)
            }
        }
        .background(MNColor.bg200)
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = MeetingDocument.seconds(fromLink: url) else { return .systemAction }
            jump(to: seconds)
            return .handled
        })
        .onChange(of: meeting.mixedAudioPath) { _, _ in player.load(url: meeting.playbackURL()) }
        .onDisappear { player.teardown() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s12) {
            titleRow
            HStack(spacing: MNSpacing.s8) {
                MeetingStatusChip(status: meeting.status)
                Text(metaText)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
                Spacer()
                if let openNote = session.openNote, meeting.vaultNotePath != nil {
                    Button("노트 열기") { openNote(meeting) }
                        .buttonStyle(MNOutlineButtonStyle())
                        .help("이 미팅의 요약 노트를 엽니다.")
                }
                if hasOverflow {
                    overflowMenu
                }
                Button("삭제") {
                    Task { await session.deleteMeeting(id: meeting.id) }
                }
                .buttonStyle(MNDangerButtonStyle())
                .help("미팅과 녹음 파일을 함께 삭제합니다.")
            }
            if let guidance = statusGuidance {
                Text(guidance)
                    .font(MNFont.body3)
                    .foregroundStyle(MNColor.contents150)
            }
            if let reason = meeting.failureReason {
                failureRow(reason)
            }
            if hasContent {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(MNSpacing.s20)
        .background(MNColor.bg100)
    }

    @ViewBuilder
    private func body(for tab: Tab) -> some View {
        if !hasContent {
            Color.clear
        } else {
            switch tab {
            case .summary:
                ScrollView {
                    MeetingSummaryView(meeting: meeting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MNSpacing.s20)
                }
            case .transcript:
                MeetingTranscriptView(meeting: meeting, player: player, jumpTarget: $jumpTarget)
                    .padding(MNSpacing.s20)
            }
        }
    }

    private func jump(to seconds: TimeInterval) {
        player.seek(to: seconds)
        jumpTarget = seconds
        tab = .transcript
    }

    private func failureRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            Text(reason)
                .font(MNFont.body3)
                .foregroundStyle(MNColor.roleRed)
            if meeting.canReprocess {
                Button(meeting.reprocessesSummaryOnly ? "요약 다시" : "다시 처리") {
                    Task { await session.reprocessMeeting(id: meeting.id) }
                }
                .buttonStyle(MNOutlineButtonStyle())
                .help(meeting.reprocessesSummaryOnly
                      ? "전사는 그대로 두고 요약만 다시 만듭니다."
                      : "남은 녹음 파일로 전사부터 다시 처리합니다.")
            }
        }
        .padding(MNSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MNColor.bgRoleRed, in: RoundedRectangle(cornerRadius: MNRadius.r8))
    }

    private var titleRow: some View {
        HStack(spacing: MNSpacing.s8) {
            if isEditingTitle {
                MNTextField("미팅 제목", text: $draftTitle, font: MNFont.title2)
                    .onSubmit { commitTitle() }
                Button("저장") { commitTitle() }
                    .buttonStyle(MNSolidButtonStyle())
                Button("취소") { isEditingTitle = false }
                    .buttonStyle(MNOutlineButtonStyle())
            } else {
                Text(meeting.title)
                    .font(MNFont.headline)
                    .foregroundStyle(MNColor.contents000)
                Button {
                    draftTitle = meeting.title
                    isEditingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(MNColor.contents150)
                }
                .buttonStyle(.plain)
                .help("제목을 수정합니다.")
            }
        }
    }

    private func commitTitle() {
        isEditingTitle = false
        let title = draftTitle
        guard title != meeting.title else { return }
        Task { await session.renameMeeting(id: meeting.id, title: title) }
    }

    private var metaText: String {
        var parts = [MNDateFormat.dayTime(meeting.startedAt ?? meeting.scheduledAt)]
        if let duration = MeetingDocument.durationText(meeting) { parts.append(duration) }
        let speakers = meeting.speakerLabels.map { meeting.displayName(for: $0) }
        if !speakers.isEmpty { parts.append(speakers.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var hasContent: Bool {
        !meeting.summary.isEmpty || !meeting.transcript.isEmpty || !meeting.segments.isEmpty
    }

    private var hasOverflow: Bool { hasContent || meeting.canReprocess }

    private var overflowMenu: some View {
        Menu {
            if meeting.canReprocess {
                Button("요약 다시") {
                    Task { await session.reprocessMeeting(id: meeting.id, summaryOnly: true) }
                }
                Button("전사부터 다시") {
                    Task { await session.reprocessMeeting(id: meeting.id, summaryOnly: false) }
                }
                if hasContent { Divider() }
            }
            if hasContent {
                if !meeting.summary.isEmpty {
                    Button("요약 복사") { copy(meeting.summary) }
                }
                if !MeetingDocument.transcriptText(meeting).isEmpty {
                    Button("전사 복사") { copy(MeetingDocument.transcriptText(meeting)) }
                }
                Button("전체 복사 (markdown)") { copy(MeetingDocument.markdown(meeting)) }
                Divider()
                Button("markdown으로 저장…") { saveMarkdown() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MNColor.contents150)
                .frame(width: 22, height: 22)
                .background(MNColor.bg300, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("재처리·내보내기")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(MeetingDocument.slug(meeting)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? MeetingDocument.markdown(meeting).write(to: url, atomically: true, encoding: .utf8)
    }

    private var statusGuidance: String? {
        switch meeting.status {
        case .scheduled:
            return "녹음이 시작되지 않은 미팅입니다. 필요 없으면 위 삭제 버튼으로 정리해 주십시오."
        case .recording:
            return nil
        case .transcribing:
            return hasContent
                ? "초벌 전사입니다. 더 정확한 전사를 만들고 있으며 끝나면 이 자리가 대체됩니다."
                : "전사를 진행하고 있습니다. 완료되면 요약과 전사가 표시됩니다."
        case .summarizing:
            return "요약을 만들고 있습니다."
        case .done, .failed:
            return nil
        }
    }
}

private struct MeetingRecordingView: View {
    @EnvironmentObject private var session: MeetingSession
    @Environment(\.meetingScreenActive) private var screenActive
    let meeting: Meeting

    var body: some View {
        if screenActive {
            live
        } else {
            Color.clear
        }
    }

    private var live: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            LiveTranscriptView(store: session.liveTranscript)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MNColor.bg200)
    }

    private var bar: some View {
        HStack(spacing: MNSpacing.s12) {
            RecordingPulse()
            Text(meeting.title)
                .font(MNFont.subtitle2)
                .foregroundStyle(MNColor.contents000)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MNDateFormat.timer(from: meeting.startedAt ?? meeting.scheduledAt,
                                        to: context.date))
                    .font(MNFont.caption1.monospacedDigit())
                    .foregroundStyle(MNColor.contents150)
            }
            .fixedSize()
            Spacer(minLength: MNSpacing.s12)
            WaveformBars(meter: session.micMeter, height: 24, barWidth: 2, maxBars: 24)
            Button("녹음 종료") {
                Task { await session.stopRecording() }
            }
            .buttonStyle(MNDangerButtonStyle())
        }
        .padding(.horizontal, MNSpacing.s20)
        .padding(.vertical, MNSpacing.s12)
        .background(MNColor.bg100)
    }
}
