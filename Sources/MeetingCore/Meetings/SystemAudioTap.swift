import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation

final class SystemTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private let live: LiveAudioSink?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var scratch: AVAudioPCMBuffer?
    private var received = 0
    private var _firstBufferAt: Date?
    var firstBufferAt: Date? { lock.withLock { _firstBufferAt } }

    init(live: LiveAudioSink? = nil) {
        self.live = live
    }

    func open(file: AVAudioFile, from source: AVAudioFormat) {
        lock.withLock {
            self.file = file
            if file.processingFormat != source {
                converter = AVAudioConverter(from: source, to: file.processingFormat)
            }
            received = 0
        }
    }

    var receivedBuffers: Int { lock.withLock { received } }

    func receive(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        var live: [Float]?
        lock.withLock {
            guard let file else { return }
            received += 1
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list,
                                               deallocator: nil),
                  input.frameLength > 0 else { return }
            if _firstBufferAt == nil { _firstBufferAt = Date() }
            if self.live != nil { live = LiveAudio.monoSamples(of: input) }
            guard let converter else {
                try? file.write(from: input)
                return
            }
            guard let output = scratchBuffer(format: file.processingFormat,
                                             frames: input.frameLength) else { return }
            output.frameLength = 0
            try? converter.convert(to: output, from: input)
            guard output.frameLength > 0 else { return }
            try? file.write(from: output)
        }
        if let live { self.live?.append(samples: live, sampleRate: format.sampleRate,
                                        track: .system) }
    }

    private func scratchBuffer(format: AVAudioFormat,
                               frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let scratch, scratch.frameCapacity >= frames { return scratch }
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 4096))
        return scratch
    }

    func close() {
        lock.withLock {
            file = nil
            converter = nil
            scratch = nil
        }
    }
}

final class SystemAudioTap: @unchecked Sendable {
    private let sink: SystemTapSink
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private let name: String

    init(name: String, live: LiveAudioSink? = nil) {
        self.name = name
        sink = SystemTapSink(live: live)
    }

    func start(name: String, in directory: URL) throws -> URL {
        let excluded = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.tapUnavailable(tapStatus)
        }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary,
                                                                 &aggregate)
        guard aggregateStatus == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            stop()
            throw TapError.aggregateUnavailable(aggregateStatus)
        }
        aggregateID = aggregate

        guard let format = Self.format(tap: tap, aggregate: aggregate) else {
            stop()
            throw TapError.formatUnavailable
        }
        let (url, file) = try Self.openFile(directory: directory, name: name, format: format)
        sink.open(file: file, from: format)

        let sink = self.sink
        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) {
            _, inputData, _, _, _ in
            sink.receive(inputData, format: format)
        }
        guard procStatus == noErr, let proc else {
            stop()
            try? FileManager.default.removeItem(at: url)
            throw TapError.ioProcUnavailable(procStatus)
        }
        procID = proc
        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            stop()
            try? FileManager.default.removeItem(at: url)
            throw TapError.startFailed(startStatus)
        }

        guard Self.attachedTapCount(aggregate: aggregate) > 0 else {
            stop()
            try? FileManager.default.removeItem(at: url)
            throw TapError.notAttached
        }
        return url
    }

    var didReceiveAudio: Bool { sink.receivedBuffers > 0 }

    var firstBufferAt: Date? { sink.firstBufferAt }

    func stop() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        sink.close()
    }

    static func openFile(directory: URL, name: String,
                         format: AVAudioFormat) throws -> (URL, AVAudioFile) {
        let compressed = directory.appendingPathComponent("\(name).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        if let file = try? AVAudioFile(forWriting: compressed, settings: settings) {
            return (compressed, file)
        }
        try? FileManager.default.removeItem(at: compressed)
        let raw = directory.appendingPathComponent("\(name).caf")
        return (raw, try AVAudioFile(forWriting: raw, settings: format.settings))
    }

    private static func attachedTapCount(aggregate: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertySubTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr
        else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func format(tap: AudioObjectID, aggregate: AudioObjectID) -> AVAudioFormat? {
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &tapAddress, 0, nil, &size, &stream) == noErr,
           let format = AVAudioFormat(streamDescription: &stream) {
            return format
        }
        var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                       mScope: kAudioDevicePropertyScopeInput,
                                                       mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(aggregate, &deviceAddress, 0, nil, &size, &stream) == noErr
        else { return nil }
        return AVAudioFormat(streamDescription: &stream)
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    enum TapError: Error, LocalizedError, CustomStringConvertible {
        case tapUnavailable(OSStatus)
        case aggregateUnavailable(OSStatus)
        case ioProcUnavailable(OSStatus)
        case startFailed(OSStatus)
        case formatUnavailable
        case notAttached

        public var description: String {
            switch self {
            case .tapUnavailable(let status):
                return "시스템 오디오 탭을 만들지 못했습니다 (OSStatus \(status))"
            case .aggregateUnavailable(let status):
                return "시스템 오디오 장치를 만들지 못했습니다 (OSStatus \(status))"
            case .ioProcUnavailable(let status):
                return "시스템 오디오 콜백을 걸지 못했습니다 (OSStatus \(status))"
            case .startFailed(let status):
                return "시스템 오디오 캡처를 시작하지 못했습니다 (OSStatus \(status))"
            case .formatUnavailable:
                return "시스템 오디오 포맷을 읽지 못했습니다"
            case .notAttached:
                return "시스템 오디오 탭이 장치에 붙지 않았습니다 — 상대 목소리가 빠집니다"
            }
        }

        public var errorDescription: String? { description }
    }
}
