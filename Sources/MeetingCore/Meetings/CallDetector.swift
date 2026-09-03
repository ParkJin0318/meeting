import Foundation
@preconcurrency import CoreAudio
@preconcurrency import ScreenCaptureKit

public struct CallDetection: Sendable, Equatable {
    public let appName: String
    public let bundleID: String
    public let windowTitle: String

    public init(appName: String, bundleID: String, windowTitle: String) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
    }

    public var suggestedTitle: String {
        windowTitle.isEmpty ? appName : windowTitle
    }

    public var origin: Meeting.Origin {
        Meeting.Origin(appName: appName, bundleID: bundleID, windowTitle: windowTitle)
    }
}

public struct ConferencingApp: Sendable, Equatable {
    public let name: String
    public let titleHints: [String]

    public init(name: String, titleHints: [String]) {
        self.name = name
        self.titleHints = titleHints
    }
}

public struct ConferencingWindow: Sendable, Equatable {
    public let appName: String
    public let title: String

    public init(appName: String, title: String) {
        self.appName = appName
        self.title = title
    }
}

public protocol CallSignaling: Sendable {
    func conferencingAppOnMicrophone() async -> String?
    func conferencingWindow(bundleID: String) async -> ConferencingWindow?
}

public actor CallDetector {
    public static let conferencingApps: [String: ConferencingApp] = [
        "com.google.Chrome": ConferencingApp(name: "Google Chrome", titleHints: ["Meet", "미트"]),
        "com.apple.Safari": ConferencingApp(name: "Safari", titleHints: ["Meet", "미트"]),
        "com.tinyspeck.slackmacgap": ConferencingApp(name: "Slack", titleHints: ["Huddle", "허들"]),
        "us.zoom.xos": ConferencingApp(name: "Zoom", titleHints: ["Zoom Meeting", "Zoom 회의"]),
        "com.microsoft.teams2": ConferencingApp(name: "Microsoft Teams",
                                                titleHints: ["Meeting", "회의"]),
    ]

    public static func conferencingKey(forBundleID bundleID: String) -> String? {
        conferencingApps.keys.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static let riseSeconds: TimeInterval = 1.5
    static let fallSeconds: TimeInterval = 15
    public static let pollSeconds: TimeInterval = 1.5

    private let signals: CallSignaling
    private let pollInterval: TimeInterval
    private var continuation: AsyncStream<CallDetection?>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var suppressed = false
    private var current: CallDetection?
    private var candidate: CallDetection?
    private var candidateSince: Date?
    private var absentSince: Date?

    public init(signals: CallSignaling = SystemCallSignals(),
                pollInterval: TimeInterval = CallDetector.pollSeconds) {
        self.signals = signals
        self.pollInterval = pollInterval
    }

    public func detections() -> AsyncStream<CallDetection?> {
        AsyncStream { continuation in
            self.continuation?.finish()
            self.continuation = continuation
            self.startPolling()
        }
    }

    public func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        if value { reset() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        let nanoseconds = UInt64(pollInterval * 1_000_000_000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(now: Date())
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    func tick(now: Date) async {
        guard !suppressed else { return }
        let detected = await detect()
        if let detected {
            absentSince = nil
            if candidate != detected {
                candidate = detected
                candidateSince = now
            }
            if current != detected, let since = candidateSince,
               now.timeIntervalSince(since) >= Self.riseSeconds {
                current = detected
                continuation?.yield(detected)
            }
        } else {
            candidate = nil
            candidateSince = nil
            if absentSince == nil { absentSince = now }
            if current != nil, let since = absentSince,
               now.timeIntervalSince(since) >= Self.fallSeconds {
                current = nil
                continuation?.yield(nil)
            }
        }
    }

    private func detect() async -> CallDetection? {
        guard let bundleID = await signals.conferencingAppOnMicrophone() else { return nil }
        if let known = current ?? candidate, known.bundleID == bundleID { return known }
        let window = await signals.conferencingWindow(bundleID: bundleID)
        return CallDetection(
            appName: window?.appName ?? Self.conferencingApps[bundleID]?.name ?? bundleID,
            bundleID: bundleID,
            windowTitle: window?.title ?? "")
    }

    private func reset() {
        candidate = nil
        candidateSince = nil
        absentSince = nil
        if current != nil {
            current = nil
            continuation?.yield(nil)
        }
    }
}

public struct SystemCallSignals: CallSignaling {
    private let selfBundleID: String
    static let soundingMark = "\u{1F50A}"

    public init(selfBundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.selfBundleID = selfBundleID
    }

    public func conferencingAppOnMicrophone() async -> String? {
        for process in Self.audioProcesses() {
            guard Self.isRunningInput(process),
                  let bundleID = Self.bundleID(of: process), !isSelf(bundleID),
                  let key = CallDetector.conferencingKey(forBundleID: bundleID)
            else { continue }
            return key
        }
        return nil
    }

    public func conferencingWindow(bundleID: String) async -> ConferencingWindow? {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        var appName: String?
        var sounding: String?
        let hints = CallDetector.conferencingApps[bundleID]?.titleHints ?? []
        for window in content.windows {
            guard let app = window.owningApplication,
                  CallDetector.conferencingKey(forBundleID: app.bundleIdentifier) == bundleID
            else { continue }
            appName = app.applicationName
            guard let title = window.title, !title.isEmpty else { continue }
            let cleaned = Self.cleanTitle(title, appName: app.applicationName)
            if hints.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                return ConferencingWindow(appName: app.applicationName, title: cleaned)
            }
            if sounding == nil, title.contains(Self.soundingMark) { sounding = cleaned }
        }
        guard let appName else { return nil }
        return ConferencingWindow(appName: appName, title: sounding ?? "")
    }

    private func isSelf(_ bundleID: String) -> Bool {
        guard !selfBundleID.isEmpty else { return false }
        return bundleID == selfBundleID || bundleID.hasPrefix(selfBundleID + ".")
    }

    private static func audioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let bundleID = value as String?, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    static func cleanTitle(_ title: String, appName: String) -> String {
        var cleaned = Substring(title)
        if let tag = cleaned.range(of: " - \(appName)") { cleaned = cleaned[..<tag.lowerBound] }
        while let last = cleaned.last, titleMarks.contains(last) { cleaned.removeLast() }
        while let first = cleaned.first, titleMarks.contains(first) { cleaned.removeFirst() }
        return String(cleaned)
    }

    private static let titleMarks: Set<Character> = [" ", "*", "\u{1F50A}", "\u{1F3E0}"]
}
