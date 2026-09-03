import SwiftUI
import MeetingCore
import MinimalUI

struct MeetingSummaryView: View {
    let meeting: Meeting

    @State private var document: MNMarkdownDocument?
    @State private var usedFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            if let document {
                MNMarkdownView(document: document)
            } else {
                Text("요약이 없습니다.")
                    .font(MNFont.body3)
                    .foregroundStyle(MNColor.contents150)
            }
            if usedFallback {
                Text("위키 노트를 읽을 수 없어 앱에 저장된 사본을 표시하고 있습니다.")
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
            }
        }
        .task(id: reloadKey) { await load() }
    }

    private var reloadKey: String {
        "\(meeting.vaultNotePath ?? "")|\(meeting.summary.count)|\(meeting.summary.prefix(64))"
    }

    private func load() async {
        let markdown = await vaultNote() ?? fallbackNote()
        guard let markdown, !Task.isCancelled else {
            document = nil
            return
        }
        let linked = MeetingDocument.linkTimecodes(in: markdown)
        let parsed = await Task.detached(priority: .userInitiated) {
            MNMarkdownDocument(parsing: linked, style: .article)
        }.value
        guard !Task.isCancelled else { return }
        document = parsed
    }

    private func vaultNote() async -> String? {
        guard let path = meeting.vaultNotePath else { return nil }
        let raw = await Task.detached(priority: .userInitiated) {
            try? String(contentsOfFile: path, encoding: .utf8)
        }.value
        guard let raw, let body = MeetingVaultExporter.summaryBody(ofNote: raw) else { return nil }
        usedFallback = false
        return body
    }

    private func fallbackNote() -> String? {
        guard !meeting.summary.isEmpty else { return nil }
        usedFallback = meeting.vaultNotePath != nil
        return meeting.summary
    }
}
