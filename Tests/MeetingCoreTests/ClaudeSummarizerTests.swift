import Testing
import Foundation
@testable import MeetingCore

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, arguments: [String], cwd: URL?, env: [String: String]?)] = []
    var result: ProcessResult
    var failure: Error?

    init(result: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: ""),
         failure: Error? = nil) {
        self.result = result
        self.failure = failure
    }

    var calls: [(executable: String, arguments: [String], cwd: URL?, env: [String: String]?)] {
        lock.withLock { _calls }
    }

    func run(_ executable: String, arguments: [String], currentDirectory: URL?,
             environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { _calls.append((executable, arguments, currentDirectory, environment)) }
        if let failure { throw failure }
        return result
    }
}

private let structuredEnvelope = """
{"duration_api_ms":2451,"stop_reason":"tool_use","session_id":"7e28f344","total_cost_usd":0.06,\
"is_error":false,"num_turns":2,"subtype":"success",\
"result":"{\\"summary\\":\\"hello\\",\\"speakers\\":{\\"S1\\":\\"Jin\\"}}",\
"structured_output":{"summary":"## 핵심 요약\\n- 김철수가 혜택 메뉴 일정을 정했다 [00:01]","speakers":{"상대1":"김철수"}},\
"type":"result","uuid":"50f93569"}
"""

@Suite struct ClaudeSummarizerTests {
    private let configuration = ClaudeSummarizer.Configuration(
        executable: "/usr/local/bin/claude", workingDirectory: URL(fileURLWithPath: "/tmp/support"))

    @Test func argumentsAskForStructuredOutputWithoutTools() {
        let args = ClaudeSummarizer.arguments(prompt: "요약하라", configuration: configuration)
        #expect(args.prefix(2) == ["-p", "요약하라"])
        #expect(args.contains("--json-schema"))
        #expect(args.contains("--output-format"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--bare"))
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--permission-mode"))
        let tools = args.firstIndex(of: "--tools").map { args[$0 + 1] }
        #expect(tools == "", "내장 도구를 전부 꺼야 한다")
        let model = args.firstIndex(of: "--model").map { args[$0 + 1] }
        #expect(model == ClaudeSummarizer.pinnedModel)
        let schema = args.firstIndex(of: "--json-schema").map { args[$0 + 1] } ?? ""
        #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil)
    }

    @Test func parsesStructuredOutputWithSpeakers() throws {
        let summary = try ClaudeSummarizer.parse(stdout: structuredEnvelope)
        #expect(summary.summary.hasPrefix("## 핵심 요약"))
        #expect(summary.speakers == ["상대1": "김철수"])
    }

    @Test func runsExecutableInSupportDirectory() async throws {
        let runner = FakeProcessRunner(
            result: ProcessResult(exitCode: 0, stdout: structuredEnvelope, stderr: ""))
        let summarizer = ClaudeSummarizer(configuration: configuration, runner: runner)
        let result = try await summarizer.summarize(prompt: "P", title: "T")
        #expect(result.speakers["상대1"] == "김철수")
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/local/bin/claude")
        #expect(call.cwd?.path == "/tmp/support")
        #expect(call.arguments.contains("--json-schema"))
    }

    @Test func structuredOutputRetryExhaustionThrows() {
        let envelope = """
        {"type":"result","subtype":"error_max_structured_output_retries","is_error":true,\
        "result":"Failed to produce valid structured output"}
        """
        #expect(throws: SummarizerError.self) {
            try ClaudeSummarizer.parse(stdout: envelope)
        }
    }

    @Test func errorEnvelopeIsNotUsedAsFallbackSummary() {
        let envelope = """
        {"type":"result","subtype":"error","is_error":true,"result":"Not logged in · Please run /login"}
        """
        #expect(throws: SummarizerError.self) {
            try ClaudeSummarizer.parse(stdout: envelope)
        }
    }

    @Test func nonZeroExitCarriesStderrTail() async {
        let runner = FakeProcessRunner(
            result: ProcessResult(exitCode: 1, stdout: "",
                                  stderr: "warning\nError: --json-schema is not valid JSON"))
        let summarizer = ClaudeSummarizer(configuration: configuration, runner: runner)
        await #expect(throws: SummarizerError.self) {
            try await summarizer.summarize(prompt: "P", title: "T")
        }
        do {
            _ = try await summarizer.summarize(prompt: "P", title: "T")
        } catch {
            #expect(error.localizedDescription.contains("--json-schema is not valid JSON"))
        }
    }

    @Test func fallsBackToTrailingJSONThenPlainText() throws {
        let trailing = """
        {"type":"result","subtype":"success","is_error":false,\
        "result":"정리했습니다.\\n{\\"summary\\": \\"## 핵심 내용\\\\n- 위젯 개선 논의\\"}"}
        """
        #expect(try ClaudeSummarizer.parse(stdout: trailing).summary == "## 핵심 내용\n- 위젯 개선 논의")

        let plain = """
        {"type":"result","subtype":"success","is_error":false,"result":"요약: 위젯 개선을 논의했습니다."}
        """
        #expect(try ClaudeSummarizer.parse(stdout: plain).summary == "요약: 위젯 개선을 논의했습니다.")
    }

    @Test func emptySummaryThrows() {
        let envelope = """
        {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"  \\n "}}
        """
        #expect(throws: SummarizerError.emptySummary) {
            try ClaudeSummarizer.parse(stdout: envelope)
        }
    }

    @Test func findsResultLineInStreamOutput() throws {
        let stream = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{}}
        {"type":"result","subtype":"success","is_error":false,"result":"x","structured_output":{"summary":"본문"}}
        """
        #expect(try ClaudeSummarizer.parse(stdout: stream).summary == "본문")
    }

    @Test func garbageIsMalformed() {
        #expect(throws: SummarizerError.self) {
            try ClaudeSummarizer.parse(stdout: "not json at all")
        }
    }
}
