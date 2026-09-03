import Testing
import Foundation
@testable import MeetingCore

final class FakeIndexRefresher: VaultIndexRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _roots: [URL] = []
    var outcome: VaultIndexRefresh = .ran

    var roots: [URL] { lock.withLock { _roots } }

    func refresh(vaultRoot: URL) async -> VaultIndexRefresh {
        lock.withLock { _roots.append(vaultRoot) }
        return outcome
    }
}

@Suite struct VaultConformanceTests {
    private func makeVault(withLog: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wiki/notes/meetings"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"),
                                                withIntermediateDirectories: true)
        if withLog {
            try "# 위키 로그\n\n## [2026-01-01] Init: 시작\n".write(
                to: root.appendingPathComponent("wiki/log.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day,
                                                   hour: hour, minute: minute))!
    }

    private func sample() -> Meeting {
        var meeting = Meeting(title: "검색팀 - 자동완성 순위 개편 Kick off 미팅",
                              scheduledAt: Self.date(2026, 8, 26, 14, 0))
        meeting.startedAt = meeting.scheduledAt
        meeting.endedAt = meeting.scheduledAt.addingTimeInterval(49 * 60)
        meeting.systemAudioPath = "/tmp/rec/abc-system.m4a"
        meeting.segments = [TranscriptSegment(speaker: "나", start: 0, end: 3, text: "시작합니다")]
        meeting.transcript = "[00:00] 나: 시작합니다"
        meeting.summary = "## 핵심 요약\n- 자동완성 순위를 바꾼다 [00:00]"
        meeting.coverage = TranscriptCoverage(duration: 2940, gaps: [.init(start: 100, end: 487)])
        return meeting
    }

    private func exporter(_ root: URL, index: FakeIndexRefresher = FakeIndexRefresher())
    -> MeetingVaultExporter {
        var exporter = MeetingVaultExporter(vaultRoot: root, generator: "meeting-app/test", index: index)
        exporter.now = { Self.date(2026, 9, 2, 10, 0) }
        return exporter
    }

    private func diskNames(_ directory: URL) throws -> [[Unicode.Scalar]] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .map { Array($0.unicodeScalars) }
    }

    private func isOnDisk(_ name: String, in directory: URL) throws -> Bool {
        try diskNames(directory).contains(Array(name.unicodeScalars))
    }

    @Test func writesNFCNamesAndLinks() throws {
        let root = try makeVault()
        let written = try #require(try exporter(root).export(sample()))
        let noteName = URL(fileURLWithPath: written.notePath).lastPathComponent
        let expectedName = "2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md"
        #expect(Array(written.notePath.unicodeScalars).suffix(expectedName.unicodeScalars.count)
                == Array(expectedName.unicodeScalars))
        #expect(noteName.utf8.count >= expectedName.utf8.count)
        let note = try String(contentsOfFile: written.notePath, encoding: .utf8)
        let href = "(../../../raw/meeting-\(expectedName))"
        #expect(note.contains(href))
        let hrefLine = note.components(separatedBy: "\n").first { $0.hasPrefix("전사 원문:") } ?? ""
        #expect(Array(hrefLine.unicodeScalars) == Array(hrefLine.precomposedStringWithCanonicalMapping.unicodeScalars),
                "href가 NFD로 적혔다")
        let transcriptPath = try #require(written.transcriptPath)
        #expect(Array(transcriptPath.unicodeScalars) == Array(transcriptPath.precomposedStringWithCanonicalMapping.unicodeScalars))
        let noteEntries = try diskNames(root.appendingPathComponent("wiki/notes/meetings"))
        #expect(noteEntries.contains(Array(expectedName.unicodeScalars)), "노트 엔트리가 NFD다: \(noteEntries)")
        #expect(try isOnDisk("meeting-\(expectedName)", in: root.appendingPathComponent("raw")),
                "전사 엔트리가 NFD다")
        #expect(try diskNames(root.appendingPathComponent("raw")).count == 1, "임시 파일이 남았다")
    }

    @Test func repairsNFDEntriesOnReexport() throws {
        let root = try makeVault()
        var meeting = sample()
        let expectedName = "2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md"
        let nfdNote = root.appendingPathComponent("wiki/notes/meetings")
            .appendingPathComponent(expectedName.decomposedStringWithCanonicalMapping)
        let nfdRaw = root.appendingPathComponent("raw")
            .appendingPathComponent("meeting-\(expectedName)".decomposedStringWithCanonicalMapping)
        try "old".write(to: nfdNote, atomically: true, encoding: .utf8)
        try "old".write(to: nfdRaw, atomically: true, encoding: .utf8)
        try #require(try !isOnDisk(expectedName, in: root.appendingPathComponent("wiki/notes/meetings")))
        meeting.vaultNotePath = nfdNote.path
        meeting.vaultTranscriptPath = nfdRaw.path

        let written = try #require(try exporter(root).export(meeting))
        let notes = root.appendingPathComponent("wiki/notes/meetings")
        #expect(try isOnDisk(expectedName, in: notes), "NFD 엔트리가 NFC로 안 바뀌었다")
        #expect(try diskNames(notes).count == 1, "NFD·NFC 두 엔트리가 남았다")
        #expect(try isOnDisk("meeting-\(expectedName)", in: root.appendingPathComponent("raw")))
        #expect(try String(contentsOfFile: written.notePath, encoding: .utf8).contains("## 핵심 요약"))
        let log = try String(contentsOf: root.appendingPathComponent("wiki/log.md"), encoding: .utf8)
        #expect(!log.contains("Fix:"), "같은 이름의 정규화 차이는 이름 변경이 아니다")
    }

    @Test func frontMatterKeepsLegacyPrefixAndAddsCommonFields() throws {
        let root = try makeVault()
        let written = try #require(try exporter(root).export(sample()))
        let note = try String(contentsOfFile: written.notePath, encoding: .utf8)
        let lines = note.components(separatedBy: "\n")
        #expect(lines[0] == "---")
        #expect(lines[1] == "type: meeting-note")
        #expect(lines[2] == "title: 검색팀 - 자동완성 순위 개편 Kick off 미팅")
        #expect(lines[3].hasPrefix("date: 2026-08-26 "))
        #expect(lines[4] == "duration: 49분")
        #expect(lines[5] == "speakers: [나]")
        #expect(lines[6] == "transcript_missing_seconds: 387")
        #expect(note.contains("sources:\n  - id: transcript\n    resource: raw/meeting-2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md"))
        #expect(note.contains("generated: { by: meeting-app/test, at: 2026-09-0"))
        #expect(note.contains("+09:00 }") || note.contains("Z }") || note.contains(":00 }"))
        #expect(note.contains("\nlifecycle: stable\n"))
        #expect(!note.contains("stale_after"))
        #expect(!note.contains("verified"))
        #expect(MeetingVaultExporter.summaryBody(ofNote: note) == "## 핵심 요약\n- 자동완성 순위를 바꾼다 [00:00]")

        let raw = try String(contentsOfFile: #require(written.transcriptPath), encoding: .utf8)
        #expect(raw.contains("type: meeting-transcript"))
        #expect(raw.contains("sources:\n  - id: recording\n    resource: \"/tmp/rec\""))
        #expect(raw.contains("lifecycle: stable"))
    }

    @Test func quotesRiskyTitles() throws {
        let root = try makeVault()
        var meeting = sample()
        meeting.title = "주간: 점검 #3"
        let written = try #require(try exporter(root).export(meeting))
        let note = try String(contentsOfFile: written.notePath, encoding: .utf8)
        #expect(note.contains("title: \"주간: 점검 #3\""))
    }

    @Test func appendsIngestLineOnceOnFirstExport() throws {
        let root = try makeVault()
        let exporter = exporter(root)
        var meeting = sample()
        let written = try #require(try exporter.export(meeting))
        #expect(written.warnings.isEmpty)
        let log = try String(contentsOf: root.appendingPathComponent("wiki/log.md"), encoding: .utf8)
        let expected = "## [2026-09-02] Ingest: 미팅 노트 — 검색팀 - 자동완성 순위 개편 Kick off 미팅 (2026-08-26, 49분) → "
            + "wiki/notes/meetings/2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md · "
            + "raw/meeting-2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md · 결측 387초 · meeting-app/test"
        #expect(log.contains(expected), "실제:\n\(log)")
        #expect(log.hasSuffix("\n"))
        #expect(log.hasPrefix("# 위키 로그\n\n## [2026-01-01] Init: 시작\n"), "append-only")

        meeting.vaultNotePath = written.notePath
        meeting.vaultTranscriptPath = written.transcriptPath
        meeting.summary = "## 핵심 요약\n- 다시 요약했다 [00:00]"
        _ = try exporter.export(meeting)
        let again = try String(contentsOf: root.appendingPathComponent("wiki/log.md"), encoding: .utf8)
        #expect(again.components(separatedBy: "Ingest: 미팅 노트").count == 2, "두 번 적혔다")
    }

    @Test func renameWritesFixLineAndRewritesLegacyLinks() throws {
        let root = try makeVault()
        let exporter = exporter(root)
        var meeting = sample()
        let written = try #require(try exporter.export(meeting))
        meeting.vaultNotePath = written.notePath
        meeting.vaultTranscriptPath = written.transcriptPath
        let oldName = "meeting-2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md"
        let referrer = root.appendingPathComponent("wiki/notes/other.md")
        try "본문 [전사](../../raw/\(oldName.decomposedStringWithCanonicalMapping)) 끝\n"
            .write(to: referrer, atomically: true, encoding: .utf8)

        meeting.title = "자동완성 킥오프"
        let moved = try #require(try exporter.export(meeting))
        #expect(moved.notePath.hasSuffix("2026-08-26-자동완성-킥오프.md"))
        #expect(!FileManager.default.fileExists(atPath: written.notePath), "옛 이름이 남았다")
        #expect(try isOnDisk("2026-08-26-자동완성-킥오프.md", in: root.appendingPathComponent("wiki/notes/meetings")),
                "옮긴 엔트리가 NFD다")
        #expect(try isOnDisk("meeting-2026-08-26-자동완성-킥오프.md", in: root.appendingPathComponent("raw")))
        let rewritten = try String(contentsOf: referrer, encoding: .utf8)
        #expect(rewritten.contains("meeting-2026-08-26-자동완성-킥오프.md"), "NFD 링크가 안 고쳐졌다: \(rewritten)")
        let log = try String(contentsOf: root.appendingPathComponent("wiki/log.md"), encoding: .utf8)
        #expect(log.contains("## [2026-09-02] Fix: 미팅 노트 이름 변경 — 2026-08-26-검색팀-자동완성-순위-개편-Kick-off-미팅.md → 2026-08-26-자동완성-킥오프.md (전사 원문·참조 함께)"))
        #expect(log.components(separatedBy: "Fix: 미팅 노트 이름 변경").count == 2, "Fix 줄은 미팅당 하나")
    }

    @Test func skipsLogWhenVaultHasNone() throws {
        let root = try makeVault(withLog: false)
        let written = try #require(try exporter(root).export(sample()))
        #expect(written.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/log.md").path))
    }

    @Test func refreshIndexDelegatesToRefresher() async throws {
        let root = try makeVault()
        let index = FakeIndexRefresher()
        let exporter = exporter(root, index: index)
        _ = try exporter.export(sample())
        #expect(await exporter.refreshIndex() == .ran)
        #expect(index.roots == [root])
    }

    @Test func wikimapRefresherSkipsWithoutScriptAndCallsUpdate() async throws {
        let root = try makeVault()
        let runner = FakeProcessRunner()
        let refresher = WikimapRefresher(runner: runner, python: "/usr/bin/python3")
        #expect(await refresher.refresh(vaultRoot: root) == .skipped("wikimap.py 없음"))
        #expect(runner.calls.isEmpty)

        try "print('ok')\n".write(to: root.appendingPathComponent("wikimap.py"), atomically: true, encoding: .utf8)
        #expect(await refresher.refresh(vaultRoot: root) == .ran)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/bin/python3")
        #expect(call.arguments == [root.appendingPathComponent("wikimap.py").path, "--root", root.path, "update"])
        #expect(call.cwd == root)

        runner.result = ProcessResult(exitCode: 1, stdout: "", stderr: "Traceback\nValueError: bad")
        #expect(await refresher.refresh(vaultRoot: root) == .failed("Traceback / ValueError: bad"))
    }

    @Test func legacyNoteStillRoundTrips() {
        let legacy = """
        ---
        type: meeting-note
        title: 옛 미팅
        date: 2026-08-01 10:00
        duration: 30분
        speakers: [나, 상대1]
        ---

        # 옛 미팅

        전사 원문: [meeting-2026-08-01-옛-미팅.md](../../../raw/meeting-2026-08-01-옛-미팅.md)

        ## 핵심 요약
        - 옛 요약 [00:10]
        """
        #expect(MeetingVaultExporter.summaryBody(ofNote: legacy) == "## 핵심 요약\n- 옛 요약 [00:10]")
    }
}
