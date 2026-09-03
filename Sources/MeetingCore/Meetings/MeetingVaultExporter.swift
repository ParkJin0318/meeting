import Foundation

public struct MeetingVaultExporter: Sendable {
    public let vaultRoot: URL
    public let generator: String
    private let index: any VaultIndexRefreshing
    var now: @Sendable () -> Date = { Date() }

    public init(vaultRoot: URL, generator: String = "meeting-app/dev",
                runner: any ProcessRunning = ShellProcessRunner()) {
        self.init(vaultRoot: vaultRoot, generator: generator,
                  index: WikimapRefresher(runner: runner))
    }

    public init(vaultRoot: URL, generator: String = "meeting-app/dev",
                index: any VaultIndexRefreshing) {
        self.vaultRoot = vaultRoot
        self.generator = generator
        self.index = index
    }

    var rawRoot: URL {
        vaultRoot.appendingPathComponent("raw")
    }

    var notesRoot: URL {
        vaultRoot.appendingPathComponent("wiki/notes/meetings")
    }

    var logURL: URL {
        vaultRoot.appendingPathComponent("wiki/log.md")
    }

    public struct Written: Sendable, Equatable {
        public let notePath: String
        public let transcriptPath: String?
        public let warnings: [String]

        public init(notePath: String, transcriptPath: String?, warnings: [String] = []) {
            self.notePath = notePath
            self.transcriptPath = transcriptPath
            self.warnings = warnings
        }
    }

    @discardableResult
    public func export(_ meeting: Meeting) throws -> Written? {
        let transcript = MeetingDocument.transcriptText(meeting)
        guard !meeting.summary.isEmpty || !transcript.isEmpty else { return nil }
        let slug = Self.nfc(MeetingDocument.slug(meeting))
        let firstExport = meeting.vaultNotePath == nil
        var moves: [(old: String, new: String)] = []

        var transcriptPath: String?
        var transcriptName: String?
        if !transcript.isEmpty {
            let name = "meeting-\(slug).md"
            let url = destination(for: meeting.vaultTranscriptPath, name: name, default: rawRoot)
            if let moved = try relocate(meeting.vaultTranscriptPath, to: url) { moves.append(moved) }
            try write(rawDocument(meeting, transcript: transcript), to: url)
            transcriptPath = Self.nfc(url.path)
            transcriptName = name
        }

        let noteURL = destination(for: meeting.vaultNotePath,
                                  name: "\(slug).md", default: notesRoot)
        let noteMove = try relocate(meeting.vaultNotePath, to: noteURL)
        if let noteMove { moves.append(noteMove) }
        try write(noteDocument(meeting, transcriptName: transcriptName), to: noteURL)
        rewriteReferences(moves)

        let notePath = Self.nfc(noteURL.path)
        var warnings: [String] = []
        do {
            try appendLog(meeting, notePath: notePath, transcriptPath: transcriptPath,
                          firstExport: firstExport, noteMove: noteMove)
        } catch {
            warnings.append("wiki/log.md 기록 실패 — \(error.localizedDescription)")
        }
        return Written(notePath: notePath, transcriptPath: transcriptPath, warnings: warnings)
    }

    public func refreshIndex() async -> VaultIndexRefresh {
        await index.refresh(vaultRoot: vaultRoot)
    }

    private func destination(for current: String?, name: String, default root: URL) -> URL {
        guard let current else { return root.appendingPathComponent(name) }
        return URL(fileURLWithPath: current).deletingLastPathComponent()
            .appendingPathComponent(name)
    }

    private func relocate(_ current: String?, to url: URL) throws -> (old: String, new: String)? {
        guard let current, Self.nfc(current) != Self.nfc(url.path) else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: current) else { return nil }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let placed = try Self.place(current, at: url.path)
        return (current, placed)
    }

    private func rewriteReferences(_ moves: [(old: String, new: String)]) {
        let pairs = moves.flatMap { move -> [(String, String)] in
            let old = Self.nfc(URL(fileURLWithPath: move.old).lastPathComponent)
            let new = Self.nfc(URL(fileURLWithPath: move.new).lastPathComponent)
            guard old != new else { return [] }
            var result: [(String, String)] = []
            for oldForm in [old, old.decomposedStringWithCanonicalMapping] {
                result.append((oldForm, new))
                if let encodedOld = oldForm.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   encodedOld != oldForm,
                   let encodedNew = new.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    result.append((encodedOld, encodedNew))
                }
            }
            return result
        }
        guard !pairs.isEmpty,
              let walker = FileManager.default.enumerator(
                at: vaultRoot, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in walker where url.pathExtension == "md" {
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var touched = false
            for (old, new) in pairs where text.contains(old) {
                let replaced = text.replacingOccurrences(of: old, with: new)
                if replaced != text {
                    text = replaced
                    touched = true
                }
            }
            if touched { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    public static func summaryBody(ofNote note: String) -> String? {
        var lines = note.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            lines.removeSubrange(0...end)
        }
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("# ") || trimmed.hasPrefix("전사 원문:")
            else { break }
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    public func remove(notePath: String?, transcriptPath: String?) {
        for path in [notePath, transcriptPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try contents.write(to: temp, atomically: false, encoding: .utf8)
        do {
            try Self.place(temp.path, at: url.path)
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    @discardableResult
    static func place(_ source: String, at destination: String) throws -> String {
        let target = nfc(destination)
        unlink(target)
        guard rename(source, target) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "\(target)로 옮기지 못했습니다"])
        }
        return target
    }

    func noteDocument(_ meeting: Meeting, transcriptName: String?) -> String {
        var sources: [String] = []
        if let transcriptName {
            sources = ["sources:",
                       "  - id: transcript",
                       "    resource: raw/\(transcriptName)",
                       "    title: \(Self.yamlScalar("\(Self.nfc(meeting.title)) — 전사"))",
                       "    last_modified: \(MeetingDocument.dateStamp(meeting.startedAt ?? meeting.scheduledAt))"]
        }
        var lines = frontMatter(meeting, kind: "meeting-note", sources: sources)
        lines.append("# \(Self.nfc(meeting.title))")
        lines.append("")
        if let transcriptName {
            lines.append("전사 원문: [\(transcriptName)](../../../raw/\(transcriptName))")
            lines.append("")
        }
        lines.append(meeting.summary.isEmpty ? "_요약이 없습니다._" : meeting.summary)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    func rawDocument(_ meeting: Meeting, transcript: String) -> String {
        var sources: [String] = []
        if let audio = meeting.systemAudioPath ?? meeting.micAudioPath {
            let directory = URL(fileURLWithPath: audio).deletingLastPathComponent().path
            sources = ["sources:",
                       "  - id: recording",
                       "    resource: \(Self.yamlScalar(Self.nfc(directory), forceQuote: true))",
                       "    title: \(Self.yamlScalar("\(Self.nfc(meeting.title)) 녹음"))",
                       "    last_modified: \(MeetingDocument.dateStamp(meeting.startedAt ?? meeting.scheduledAt))"]
        }
        var lines = frontMatter(meeting, kind: "meeting-transcript", sources: sources)
        lines.append("# \(Self.nfc(meeting.title)) — 전사")
        lines.append("")
        if let coverage = meeting.coverage, let note = coverage.note {
            lines.append("> \(note)")
            for gap in coverage.gaps { lines.append("> - \(gap.label)") }
            lines.append("")
        }
        lines.append(transcript)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func frontMatter(_ meeting: Meeting, kind: String, sources: [String]) -> [String] {
        var lines = ["---", "type: \(kind)",
                     "title: \(Self.yamlScalar(Self.nfc(meeting.title)))",
                     "date: \(MeetingDocument.timestamp(meeting.startedAt ?? meeting.scheduledAt))"]
        if let duration = MeetingDocument.durationText(meeting) {
            lines.append("duration: \(duration)")
        }
        let speakers = meeting.speakerLabels.map { Self.nfc(meeting.displayName(for: $0)) }
        if !speakers.isEmpty {
            lines.append("speakers: [\(speakers.joined(separator: ", "))]")
        }
        if let coverage = meeting.coverage, coverage.hasLoss {
            lines.append("transcript_missing_seconds: \(Int(coverage.missingSeconds.rounded()))")
        }
        lines.append(contentsOf: sources)
        lines.append("generated: { by: \(generator), at: \(Self.isoLocal(now())) }")
        lines.append("lifecycle: stable")
        lines.append(contentsOf: ["---", ""])
        return lines
    }

    private func appendLog(_ meeting: Meeting, notePath: String, transcriptPath: String?,
                           firstExport: Bool, noteMove: (old: String, new: String)?) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logURL.path) else { return }
        let today = MeetingDocument.dateStamp(now())
        var entries: [String] = []
        if firstExport {
            var when = MeetingDocument.dateStamp(meeting.startedAt ?? meeting.scheduledAt)
            if let duration = MeetingDocument.durationText(meeting) { when += ", \(duration)" }
            var parts = [relative(notePath)]
            if let transcriptPath { parts.append(relative(transcriptPath)) }
            if let coverage = meeting.coverage, coverage.hasLoss {
                parts.append("결측 \(Int(coverage.missingSeconds.rounded()))초")
            }
            parts.append(generator)
            entries.append("## [\(today)] Ingest: 미팅 노트 — \(Self.nfc(meeting.title)) (\(when)) → "
                           + parts.joined(separator: " · "))
        }
        if let noteMove {
            let old = Self.nfc(URL(fileURLWithPath: noteMove.old).lastPathComponent)
            let new = Self.nfc(URL(fileURLWithPath: noteMove.new).lastPathComponent)
            if old != new {
                entries.append("## [\(today)] Fix: 미팅 노트 이름 변경 — \(old) → \(new) (전사 원문·참조 함께)")
            }
        }
        guard !entries.isEmpty else { return }
        var text = try String(contentsOf: logURL, encoding: .utf8)
        if !text.hasSuffix("\n") { text += "\n" }
        if !text.hasSuffix("\n\n") { text += "\n" }
        text += entries.joined(separator: "\n\n") + "\n"
        try text.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func relative(_ path: String) -> String {
        let root = Self.nfc(vaultRoot.path) + "/"
        let full = Self.nfc(path)
        return full.hasPrefix(root) ? String(full.dropFirst(root.count)) : full
    }

    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    static func yamlScalar(_ text: String, forceQuote: Bool = false) -> String {
        let risky = text.isEmpty || forceQuote
            || text.contains(": ") || text.contains(" #") || text.hasSuffix(":")
            || "[]{}*&!|>'\"%@`,".contains(text.first ?? " ")
        guard risky else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func isoLocal(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
