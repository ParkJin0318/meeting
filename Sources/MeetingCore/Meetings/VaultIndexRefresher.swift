import Foundation

public enum VaultIndexRefresh: Sendable, Equatable {
    case ran
    case skipped(String)
    case failed(String)
}

public protocol VaultIndexRefreshing: Sendable {
    func refresh(vaultRoot: URL) async -> VaultIndexRefresh
}

public actor WikimapRefresher: VaultIndexRefreshing {
    private let runner: any ProcessRunning
    private let python: String
    private let timeout: TimeInterval
    private var tail: Task<VaultIndexRefresh, Never>?

    public init(runner: any ProcessRunning = ShellProcessRunner(),
                python: String = "/usr/bin/python3",
                timeout: TimeInterval = 60) {
        self.runner = runner
        self.python = python
        self.timeout = timeout
    }

    public func refresh(vaultRoot: URL) async -> VaultIndexRefresh {
        let previous = tail
        let task = Task { [runner, python, timeout] in
            _ = await previous?.value
            return await Self.run(vaultRoot: vaultRoot, runner: runner, python: python, timeout: timeout)
        }
        tail = task
        return await task.value
    }

    private static func run(vaultRoot: URL, runner: any ProcessRunning,
                            python: String, timeout: TimeInterval) async -> VaultIndexRefresh {
        let script = vaultRoot.appendingPathComponent("wikimap.py")
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path) else { return .skipped("wikimap.py 없음") }
        guard fm.isExecutableFile(atPath: python) else { return .skipped("\(python) 없음") }
        do {
            let result = try await runner.run(
                python, arguments: [script.path, "--root", vaultRoot.path, "update"],
                currentDirectory: vaultRoot, environment: nil, timeout: timeout)
            guard result.succeeded else {
                let output = result.stderr.isEmpty ? result.stdout : result.stderr
                let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                return .failed(lines.suffix(3).joined(separator: " / "))
            }
            return .ran
        } catch {
            return .failed(String(describing: error))
        }
    }
}
