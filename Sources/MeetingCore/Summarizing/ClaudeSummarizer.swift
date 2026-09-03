import Foundation

public struct ClaudeSummarizer: MeetingSummarizing {
    public struct Configuration: Sendable {
        public var executable: String
        public var model: String
        public var effort: String
        public var timeout: TimeInterval
        public var workingDirectory: URL?

        public init(executable: String,
                    model: String = ClaudeSummarizer.pinnedModel,
                    effort: String = ClaudeSummarizer.pinnedEffort,
                    timeout: TimeInterval = 1800,
                    workingDirectory: URL? = nil) {
            self.executable = executable
            self.model = model
            self.effort = effort
            self.timeout = timeout
            self.workingDirectory = workingDirectory
        }
    }

    public static let pinnedModel = "claude-opus-5"
    public static let pinnedEffort = "xhigh"

    static let schemaJSON = #"""
    {"type":"object","required":["summary"],"properties":{"summary":{"type":"string","description":"markdown 요약 본문 전체"},"speakers":{"type":"object","additionalProperties":{"type":"string"},"description":"전사의 자동 라벨(나·상대1·화자2)→사람 이름. 신원이 드러난 라벨만"}}}
    """#

    private let configuration: Configuration
    private let runner: any ProcessRunning

    public init(configuration: Configuration, runner: any ProcessRunning = ShellProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    public func summarize(prompt: String, title: String) async throws -> MeetingSummary {
        let result: ProcessResult
        do {
            result = try await runner.run(
                configuration.executable,
                arguments: Self.arguments(prompt: prompt, configuration: configuration),
                currentDirectory: configuration.workingDirectory,
                environment: nil, timeout: configuration.timeout)
        } catch ProcessError.timedOut {
            throw SummarizerError.timedOut(configuration.timeout)
        } catch {
            throw SummarizerError.launchFailed(String(describing: error))
        }
        guard result.succeeded else {
            throw SummarizerError.exitCode(result.exitCode, stderrTail: Self.tail(result.stderr))
        }
        return try Self.parse(stdout: result.stdout)
    }

    static func arguments(prompt: String, configuration: Configuration) -> [String] {
        [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", schemaJSON,
            "--model", configuration.model,
            "--effort", configuration.effort,
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--disable-slash-commands",
        ]
    }

    static func parse(stdout: String) throws -> MeetingSummary {
        guard let envelope = resultEnvelope(stdout) else {
            throw SummarizerError.malformedOutput(Self.tail(stdout))
        }
        let subtype = envelope["subtype"] as? String
        if envelope["is_error"] as? Bool == true || subtype == "error_max_structured_output_retries" {
            throw SummarizerError.structuredOutputMissing(
                subtype: subtype, detail: envelope["result"] as? String)
        }
        if let structured = envelope["structured_output"] as? [String: Any] {
            let summary = (structured["summary"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw SummarizerError.emptySummary }
            let speakers = (structured["speakers"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:]
            return MeetingSummary(summary: summary, speakers: speakers)
        }
        if let text = envelope["result"] as? String {
            let summary = (TrailingJSON.extract(from: text)?["summary"] as? String ?? text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw SummarizerError.emptySummary }
            return MeetingSummary(summary: summary)
        }
        throw SummarizerError.structuredOutputMissing(subtype: subtype, detail: nil)
    }

    static func resultEnvelope(_ stdout: String) -> [String: Any]? {
        if let data = stdout.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        for line in stdout.split(separator: "\n").reversed() {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "result" else { continue }
            return object
        }
        return nil
    }

    private static func tail(_ text: String, lines: Int = 5) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SummarizerError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(TimeInterval)
    case exitCode(Int32, stderrTail: String)
    case structuredOutputMissing(subtype: String?, detail: String?)
    case malformedOutput(String)
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "claude를 실행하지 못했습니다 (\(reason))"
        case .timedOut(let seconds):
            return "요약이 \(Int(seconds))초 안에 끝나지 않았습니다"
        case .exitCode(let code, let stderrTail):
            return stderrTail.isEmpty
                ? "claude가 종료 코드 \(code)로 끝났습니다"
                : "claude가 종료 코드 \(code)로 끝났습니다: \(stderrTail)"
        case .structuredOutputMissing(let subtype, let detail):
            let what = detail.map { ": \($0)" } ?? ""
            return "구조화 출력이 없습니다 (\(subtype ?? "unknown"))\(what)"
        case .malformedOutput(let tail):
            return "결과를 읽지 못했습니다: \(tail)"
        case .emptySummary:
            return "요약이 비어 있습니다."
        }
    }
}
