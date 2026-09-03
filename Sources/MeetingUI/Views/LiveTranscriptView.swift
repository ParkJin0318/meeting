import SwiftUI
import MeetingCore
import MinimalUI

struct LiveTranscriptView: View {
    @ObservedObject var store: LiveTranscriptStore
    @State private var follows = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MNSpacing.s8) {
                        ForEach(Array(store.confirmed.enumerated()), id: \.offset) { index, line in
                            row(speaker: line.speaker, text: line.text, isPending: false)
                                .id(index)
                        }
                        if !store.pending.isEmpty {
                            row(speaker: nil, text: store.pending, isPending: true)
                                .id(pendingID)
                        }
                        if store.isEmpty {
                            Text(store.notice ?? "듣고 있습니다. 말이 시작되면 여기에 옮겨 적습니다.")
                                .font(MNFont.body3)
                                .foregroundStyle(MNColor.contents150)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MNSpacing.s20)
                }
                .onChange(of: store.confirmed.count) { _, _ in scroll(proxy) }
                .onChange(of: store.pending) { _, _ in scroll(proxy) }
                .simultaneousGesture(DragGesture().onChanged { _ in follows = false })
            }
            if !follows {
                Button("맨 아래로") { follows = true }
                    .buttonStyle(MNOutlineButtonStyle())
                    .padding(MNSpacing.s16)
            }
            if let notice = store.notice, !store.isEmpty {
                Text(notice)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
                    .padding(MNSpacing.s8)
            }
        }
    }

    private var pendingID: String { "pending" }

    private func row(speaker: String?, text: String, isPending: Bool) -> some View {
        HStack(alignment: .top, spacing: MNSpacing.s8) {
            if let speaker {
                Text(speaker)
                    .font(MNFont.caption1)
                    .foregroundStyle(MeetingTranscriptView.color(for: speaker))
                    .frame(width: 56, alignment: .leading)
            } else {
                Spacer().frame(width: 56)
            }
            Text(text)
                .font(MNFont.body3)
                .foregroundStyle(isPending ? MNColor.contents200 : MNColor.contents100)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard follows else { return }
        let target = store.pending.isEmpty ? store.confirmed.count - 1 : nil
        withAnimation(.easeOut(duration: 0.2)) {
            if let target, target >= 0 {
                proxy.scrollTo(target, anchor: .bottom)
            } else if !store.pending.isEmpty {
                proxy.scrollTo(pendingID, anchor: .bottom)
            }
        }
    }
}
