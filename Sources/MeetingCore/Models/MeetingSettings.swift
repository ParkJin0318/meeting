import Foundation

public struct MeetingSettings: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "meeting-settings" }

    public var claudeExecutable: String
    public var vaultPath: String
    public var transcriptionLanguage: String
    public var transcriptionGlossary: String
    public var liveTranscription: Bool
    public var boostInputVolume: Bool

    public init(claudeExecutable: String = "claude",
                vaultPath: String = "",
                transcriptionLanguage: String = "ko",
                transcriptionGlossary: String = "",
                liveTranscription: Bool = true,
                boostInputVolume: Bool = true) {
        self.claudeExecutable = claudeExecutable
        self.vaultPath = vaultPath
        self.transcriptionLanguage = transcriptionLanguage
        self.transcriptionGlossary = transcriptionGlossary
        self.liveTranscription = liveTranscription
        self.boostInputVolume = boostInputVolume
    }

    public var summarizes: Bool {
        !claudeExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case claudeExecutable, vaultPath, transcriptionLanguage, transcriptionGlossary
        case liveTranscription, boostInputVolume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeExecutable = try c.decodeIfPresent(String.self, forKey: .claudeExecutable) ?? "claude"
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? ""
        transcriptionLanguage = try c.decodeIfPresent(String.self,
                                                      forKey: .transcriptionLanguage) ?? "ko"
        transcriptionGlossary = try c.decodeIfPresent(String.self,
                                                      forKey: .transcriptionGlossary) ?? ""
        liveTranscription = try c.decodeIfPresent(Bool.self, forKey: .liveTranscription) ?? true
        boostInputVolume = try c.decodeIfPresent(Bool.self, forKey: .boostInputVolume) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claudeExecutable, forKey: .claudeExecutable)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
        try c.encode(transcriptionGlossary, forKey: .transcriptionGlossary)
        try c.encode(liveTranscription, forKey: .liveTranscription)
        try c.encode(boostInputVolume, forKey: .boostInputVolume)
    }
}
