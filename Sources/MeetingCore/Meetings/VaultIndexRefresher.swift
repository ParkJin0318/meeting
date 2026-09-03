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

    /// 벤더링본이 있을 수 있는 자리. 볼트가 2026-09-16 에 실행 코드를 `script/` 로 모았고,
    /// 옛 배치(루트)도 계속 받는다 — 설치된 앱이 볼트보다 늦게 갱신되기 때문이다.
    public static let scriptCandidates = ["script/wikimap.py", "wikimap.py"]

    public static func locateScript(in vaultRoot: URL,
                                    fileManager fm: FileManager = .default) -> URL? {
        for rel in scriptCandidates {
            let url = vaultRoot.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func run(vaultRoot: URL, runner: any ProcessRunning,
                            python: String, timeout: TimeInterval) async -> VaultIndexRefresh {
        let fm = FileManager.default
        guard let script = locateScript(in: vaultRoot, fileManager: fm) else {
            return .skipped("wikimap.py 없음")
        }
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
