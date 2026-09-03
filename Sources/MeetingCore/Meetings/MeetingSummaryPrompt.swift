import Foundation

enum MeetingSummaryPrompt {
    static func build(title: String, transcript: String, glossary: String,
                      speakerNames: [String: String],
                      coverage: TranscriptCoverage? = nil,
                      language: String = "ko") -> String {
        var lines = [
            "다음 미팅 전사를 markdown으로 요약하라.",
            "",
            "# 섹션",
            "항상 넣는다:",
            "- `## 핵심 요약` — 이 미팅을 한 화면으로 줄이면 무엇인가. 3~5줄",
            "- `## 후속 조치` — 누가 무엇을 하기로 했는가. 없으면 \"없습니다.\" 한 줄",
            "",
            "해당할 때만 넣는다. 해당 없으면 그 섹션째 빼라 — 빈 섹션을 남기지 마라:",
            "- `## 핵심 메시지` — 화자가 관철하려는 주장이 있을 때(강연·발표).",
            "  주장을 굵게 한 줄로 세우고 그 아래 근거를 붙인다",
            "- `## 주요 내용` — 다룬 주제가 여럿일 때. `### 1. 소제목`으로 나눠 쓴다",
            "- `## 주요 용어` — **화자가 전사에서 직접 설명한** 용어만. `**용어**: 뜻` 한 줄씩.",
            "  네가 아는 뜻을 채워 넣지 마라. 참석자가 매일 쓰는 사내 약어는 설명이 필요 없다",
            "- `## Q&A` — 질의응답 **시간이 따로 있었을 때**. 진행 중 오간 확인 질문은",
            "  `## 주요 내용`·`## 후속 조치`에 넣고 여기로 옮겨 적지 마라(같은 말이 두 번 나온다)",
            "- `## 결정 사항` — **실제로 정한 것이 있을 때만**.",
            "  계획 소개·일정 공유·커리큘럼 안내는 결정이 아니다",
            "",
            "# 쓰는 법",
            "- 수치·고유명사·사례는 원문 그대로 옮겨라. \"가입자 32만 명\", \"응답 시간 200ms → 4초\",",
            "  \"3월~8월 전수 조사\"처럼 구체적인 것이 이 문서의 값어치다.",
            "  \"공유 자원 문제\", \"관측이 중요하다\"처럼 뭉뚱그리면 읽을 이유가 없어진다",
            "- 각 항목 끝에 근거가 되는 전사 시각을 `[mm:ss]` 형식으로 하나만 달아라 —",
            "  사람이 그 숫자를 눌러 원문을 확인한다. 전사에 없는 시각을 지어내지 마라.",
            "  `## 주요 용어`만 예외다(용어 정의는 특정 시각의 발화가 아니다)",
            "- 전사에 없는 내용을 채워 넣지 마라. 모르면 쓰지 않는다",
            "- 한 섹션 안의 항목은 **전사 시각 오름차순**으로 놓아라 —",
            "  같은 주제가 회의 앞뒤로 나뉘어 나왔어도 시각 순서를 지킨다",
        ]

        if let coverage, coverage.hasLoss {
            lines += [
                "",
                "# 전사가 끊긴 자리",
                "전사 본문의 `⟨전사 없음 · N초⟩` 줄은 그 시간만큼 받아쓰기가 없다는 뜻이다.",
                "그 줄을 사이에 두고 앞뒤를 한 흐름으로 잇지 마라 — 사이에 다른 주제가",
                "통째로 들어 있었을 수 있다. 끊긴 자리 너머를 추측해 메우지도 마라.",
                "끊긴 구간이 \(coverage.gaps.count)곳"
                    + " · 합계 \(Int(coverage.missingSeconds.rounded()))초다.",
            ]
        }

        let dictionary = correctionDictionary(glossary: glossary, speakerNames: speakerNames)
        if !dictionary.isEmpty {
            lines += [
                "",
                "# 표기 사전",
                "전사는 기계가 받아쓴 것이라 고유명사가 무너져 있다"
                    + "(\"파이프라인\"이 \"파이브라인\"으로, \"리버스 프록시\"가 \"리버스 프로 시청\"으로).",
                "아래 표기를 알고 읽되, 여기 없는 말을 지어내지는 마라.",
                dictionary.joined(separator: ", "),
            ]
        }

        lines += [
            "",
            "# 화자 이름",
            "전사의 화자는 자동 라벨이다 — 통화는 `나`·`상대1`·`상대2`,",
            "대면 회의는 한 트랙에 전원이 담기므로 `화자1`·`화자2`(번호는 띄엄띄엄할 수 있다).",
            "전사 안에서 신원이 드러나면",
            "(자기소개 \"저는 …입니다\", 호명 \"○○님\") 출력의 `speakers` 필드에",
            "라벨→이름으로 담아라. 확실하지 않은 라벨은 넣지 마라 — 사람이 확인하고 반영한다.",
            "",
            "# 출력",
            "요약 본문은 \(languageName(language))로 써라 — 섹션 제목도 그 말로 옮긴다.",
            "완성한 markdown 요약은 출력의 `summary` 필드에 통째로 담아라.",
            "필드 밖에 다른 텍스트를 내지 마라. 화자 제안이 없으면 `speakers`는 비워 둔다.",
            "",
            "미팅: \(title)",
            "전사:",
            transcript,
        ]
        return lines.joined(separator: "\n")
    }

    private static func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "한국어" }
        return Locale(identifier: trimmed).localizedString(forLanguageCode: trimmed) ?? trimmed
    }

    private static func correctionDictionary(glossary: String,
                                             speakerNames: [String: String]) -> [String] {
        var terms: [String] = []
        let trimmed = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            terms += trimmed.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        terms += speakerNames.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        return terms.sorted().filter { seen.insert($0).inserted }
    }
}
