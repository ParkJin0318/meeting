import Foundation

public struct MeetingPaths: Sendable, Equatable {
    public let supportDirectory: URL

    public init(appSupportName: String,
                base: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask)[0]) {
        supportDirectory = base.appendingPathComponent(appSupportName)
    }

    public var recordings: URL { supportDirectory.appendingPathComponent("recordings") }
    public var models: URL { supportDirectory.appendingPathComponent("models") }
    public var diarization: URL { supportDirectory.appendingPathComponent("diarization") }
    public var database: URL {
        supportDirectory.appendingPathComponent("\(supportDirectory.lastPathComponent).sqlite3")
    }
}

public struct MeetingHostProfile: Sendable, Equatable {
    public let appSupportName: String
    public let displayName: String
    public let paths: MeetingPaths

    public init(appSupportName: String, displayName: String,
                base: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask)[0]) {
        self.appSupportName = appSupportName
        self.displayName = displayName
        self.paths = MeetingPaths(appSupportName: appSupportName, base: base)
    }

    public var audioTapName: String { "\(appSupportName)-system-audio" }
}
