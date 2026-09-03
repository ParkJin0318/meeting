import Foundation

public struct DiarizationSetup: Sendable, Equatable {
    public static var bundledScriptURL: URL? {
        Bundle.module.url(forResource: "diarize", withExtension: "py")
    }

    public let supportRoot: URL
    public let scriptPath: String?
    public let missing: [String]

    public var isReady: Bool { scriptPath != nil && missing.isEmpty }

    public init(supportRoot: URL, fileManager: FileManager = .default,
                script: URL? = DiarizationSetup.bundledScriptURL) {
        self.supportRoot = supportRoot
        var missing: [String] = []
        if let script, fileManager.fileExists(atPath: script.path) {
            self.scriptPath = script.path
        } else {
            self.scriptPath = nil
            missing.append("분리 스크립트(diarize.py 번들)")
        }
        if !fileManager.isExecutableFile(
            atPath: supportRoot.appendingPathComponent("venv/bin/python3").path) {
            missing.append("전용 python 환경(venv)")
        }
        let models = supportRoot.appendingPathComponent("models")
        if !fileManager.fileExists(atPath: models
            .appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0/model.onnx").path) {
            missing.append("분할 모델(pyannote segmentation)")
        }
        if !fileManager.fileExists(atPath: models
            .appendingPathComponent("3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
            .path) {
            missing.append("화자 임베딩 모델(3D-Speaker)")
        }
        self.missing = missing
    }

    public var summary: String {
        isReady
            ? "화자 구분 준비됨 — 미팅에서 화자를 나눠 기록합니다."
            : "화자 구분 미설치 — \(missing.joined(separator: ", "))이(가) 없습니다."
                + " 없으면 온라인 통화의 상대가 한 사람으로 묶이고 대면 미팅은 화자를 나누지 않습니다."
    }

    public var installHint: String {
        "scripts/setup-diarization.sh \"\(supportRoot.path)\""
    }
}
