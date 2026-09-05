import Foundation
@preconcurrency import AVFoundation

final class MicTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var levels: AsyncStream<Float>.Continuation?
    private var paused = false
    private(set) var droppedAfterClose = 0
    private var _firstBufferAt: Date?
    var firstBufferAt: Date? { lock.withLock { _firstBufferAt } }

    init() {}

    func open(file: AVAudioFile?) {
        lock.withLock { self.file = file }
    }

    func subscribe(_ continuation: AsyncStream<Float>.Continuation?) {
        let previous: AsyncStream<Float>.Continuation? = lock.withLock {
            let previous = levels
            levels = continuation
            return previous
        }
        previous?.finish()
    }

    /// `close()`가 풀어 준다 — 열기 전에 걸린 pause는 그대로 살아 "멈춘 채 시작"이 된다.
    func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
    }

    /// 버퍼를 받아들였으면 true. 닫힌 뒤나 멈춘 동안은 false — 호출자는 이 값으로 라이브 전달을 막는다.
    @discardableResult
    func receive(_ buffer: AVAudioPCMBuffer?, level: @Sendable () -> Float) -> Bool {
        lock.withLock {
            guard file != nil || levels != nil else {
                droppedAfterClose += 1
                return false
            }
            if paused {
                levels?.yield(0)
                return false
            }
            if _firstBufferAt == nil, buffer != nil { _firstBufferAt = Date() }
            if let buffer { try? file?.write(from: buffer) }
            levels?.yield(level())
            return true
        }
    }

    func close() {
        let previous: AsyncStream<Float>.Continuation? = lock.withLock {
            file = nil
            paused = false
            let previous = levels
            levels = nil
            return previous
        }
        previous?.finish()
    }
}

public final class SystemAudioMeetingRecorder: MeetingRecording, @unchecked Sendable {

    private let recordingsDirectory: URL
    private let micTap = MicTapState()
    private let systemTap: SystemAudioTap
    private let live: LiveAudioSink?
    private let boostsInputVolume: Bool
    private var restoreInputVolume: Float?
    private var micEngine: AVAudioEngine?
    private var currentSystemURL: URL?
    private var currentMicURL: URL?

    public init(recordingsDirectory: URL, tapName: String, live: LiveAudioSink? = nil,
                boostsInputVolume: Bool = true) {
        self.recordingsDirectory = recordingsDirectory
        self.live = live
        self.boostsInputVolume = boostsInputVolume
        self.systemTap = SystemAudioTap(name: tapName, live: live)
    }

    public func start(meetingID: String) async throws {
        try FileManager.default.createDirectory(at: recordingsDirectory,
                                                withIntermediateDirectories: true)
        currentSystemURL = try systemTap.start(name: "\(meetingID)-system",
                                               in: recordingsDirectory)
        restoreInputVolume = boostsInputVolume ? InputDeviceVolume.raise() : nil
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let (micURL, micFile) = try Self.openMicFile(directory: recordingsDirectory,
                                                         meetingID: meetingID, format: format)
            micTap.open(file: micFile)
            let micTap = self.micTap
            let live = self.live
            let sampleRate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard micTap.receive(buffer, level: {
                    SystemAudioMeetingRecorder.meterLevel(of: buffer)
                }), let live else { return }
                live.append(samples: LiveAudio.monoSamples(of: buffer),
                            sampleRate: sampleRate, track: .mic)
            }
            try engine.start()
            self.micEngine = engine
            self.currentMicURL = micURL
        } catch {
            systemTap.stop()
            micTap.close()
            restoreInputVolumeIfNeeded()
            currentSystemURL = nil
            throw error
        }
    }

    public func stop() async throws -> RecordedAudio {
        systemTap.stop()
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micTap.close()
        restoreInputVolumeIfNeeded()
        var systemURL = currentSystemURL
        if !systemTap.didReceiveAudio {
            if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            systemURL = nil
        }
        var offset: TimeInterval = 0
        if let systemStart = systemTap.firstBufferAt, let micStart = micTap.firstBufferAt {
            offset = micStart.timeIntervalSince(systemStart)
        }
        let audio = RecordedAudio(systemAudioURL: systemURL, micURL: currentMicURL,
                                  micStartOffset: offset)
        micEngine = nil
        currentSystemURL = nil
        currentMicURL = nil
        return audio
    }

    /// 캡처는 계속 돌린다 — 탭을 부수면 재개 때 파일을 새로 열어 앞부분을 덮어쓰고,
    /// 엔진을 다시 켜면 쉬는 동안 입력 장치가 바뀐 경우 포맷 불일치로 죽는다.
    public func setPaused(_ paused: Bool) {
        micTap.setPaused(paused)
        systemTap.setPaused(paused)
    }

    private func restoreInputVolumeIfNeeded() {
        guard let previous = restoreInputVolume else { return }
        restoreInputVolume = nil
        InputDeviceVolume.set(previous)
    }

    public func micLevels() -> AsyncStream<Float> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { micTap.subscribe($0) }
    }

    static func openMicFile(directory: URL, meetingID: String,
                            format: AVAudioFormat) throws -> (URL, AVAudioFile) {
        let compressed = directory.appendingPathComponent("\(meetingID)-mic.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount)
        ]
        if let file = try? AVAudioFile(forWriting: compressed, settings: settings),
           file.processingFormat == format {
            return (compressed, file)
        }
        try? FileManager.default.removeItem(at: compressed)
        let raw = directory.appendingPathComponent("\(meetingID)-mic.caf")
        return (raw, try AVAudioFile(forWriting: raw, settings: format.settings))
    }

    static func meterLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        return meterLevel(rms: (sum / Float(count)).squareRoot())
    }

    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
