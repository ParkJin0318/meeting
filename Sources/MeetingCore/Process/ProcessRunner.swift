import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String],
             currentDirectory: URL?, environment: [String: String]?,
             timeout: TimeInterval) async throws -> ProcessResult

    func runStreaming(_ executable: String, arguments: [String],
                      currentDirectory: URL?, environment: [String: String]?,
                      timeout: TimeInterval,
                      onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: String, arguments: [String],
                    currentDirectory: URL? = nil) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, currentDirectory: currentDirectory,
                      environment: nil, timeout: 1800)
    }

    public func runStreaming(_ executable: String, arguments: [String],
                             currentDirectory: URL?, environment: [String: String]?,
                             timeout: TimeInterval,
                             onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let result = try await run(executable, arguments: arguments,
                                   currentDirectory: currentDirectory,
                                   environment: environment, timeout: timeout)
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            onLine(String(line))
        }
        return result
    }
}

public enum ProcessError: Error {
    case launchFailed(String)
    case timedOut(String)
}

public protocol CancellableProcessRunning: ProcessRunning {
    func runStreaming(_ executable: String, arguments: [String],
                      currentDirectory: URL?, environment: [String: String]?,
                      timeout: TimeInterval,
                      onLaunch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
                      onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

public struct ShellProcessRunner: ProcessRunning, CancellableProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String],
                    currentDirectory: URL?, environment: [String: String]?,
                    timeout: TimeInterval) async throws -> ProcessResult {
        try await runStreaming(executable, arguments: arguments,
                               currentDirectory: currentDirectory,
                               environment: environment, timeout: timeout,
                               onLine: { _ in })
    }

    public func runStreaming(_ executable: String, arguments: [String],
                             currentDirectory: URL?, environment: [String: String]?,
                             timeout: TimeInterval,
                             onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try await runStreaming(executable, arguments: arguments,
                               currentDirectory: currentDirectory,
                               environment: environment, timeout: timeout,
                               onLaunch: { _ in }, onLine: onLine)
    }

    public func runStreaming(_ executable: String, arguments: [String],
                             currentDirectory: URL?, environment: [String: String]?,
                             timeout: TimeInterval,
                             onLaunch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
                             onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        var env = ProcessInfo.processInfo.environment
        if let environment {
            env.merge(environment) { _, new in new }
        }
        let path = env["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var prepend: [String] = []
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        where !path.contains(dir) {
            prepend.append(dir)
        }
        if !prepend.isEmpty {
            env["PATH"] = (prepend + [path]).joined(separator: ":")
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class OutputBox: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let box = OutputBox()

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessError.launchFailed("\(executable): \(error)"))
                return
            }
            let pid = process.processIdentifier
            onLaunch { kill(pid, SIGTERM) }
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = outPipe.fileHandleForReading
                var pending = Data()
                let newline = Data([0x0A])
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.out.append(chunk)
                    pending.append(chunk)
                    while let range = pending.range(of: newline) {
                        let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
                        pending.removeSubrange(pending.startIndex..<range.upperBound)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            onLine(line)
                        }
                    }
                }
                if !pending.isEmpty, let line = String(data: pending, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: ProcessError.timedOut(executable))
                    return
                }
                group.wait()
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: box.out, encoding: .utf8) ?? "",
                    stderr: String(data: box.err, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
