import Testing
import Foundation
import AVFoundation
@testable import MeetingCore

@Suite struct MicTapStateTests {

    @Test func closedTapDropsLateCallbacks() {
        let tap = MicTapState()
        tap.open(file: nil)
        tap.subscribe(AsyncStream<Float>.makeStream().continuation)

        tap.receive(nil) { 0.5 }
        #expect(tap.droppedAfterClose == 0)

        tap.close()
        tap.receive(nil) { 0.5 }
        tap.receive(nil) { 0.5 }
        #expect(tap.droppedAfterClose == 2)
    }

    @Test func resubscribeFinishesPreviousStream() async {
        let tap = MicTapState()
        let first = AsyncStream<Float>.makeStream()
        tap.subscribe(first.continuation)

        let second = AsyncStream<Float>.makeStream()
        tap.subscribe(second.continuation)

        tap.receive(nil) { 0.7 }
        tap.close()

        var firstValues: [Float] = []
        for await value in first.stream { firstValues.append(value) }
        #expect(firstValues.isEmpty)

        var secondValues: [Float] = []
        for await value in second.stream { secondValues.append(value) }
        #expect(secondValues == [0.7])
    }

    @Test func concurrentReceiveSubscribeCloseIsSafe() async {
        let tap = MicTapState()
        tap.open(file: nil)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<500 { tap.receive(nil) { 0.3 } }
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    tap.subscribe(AsyncStream<Float>.makeStream().continuation)
                }
            }
            group.addTask {
                tap.close()
            }
        }

        tap.close()
        tap.receive(nil) { 0.1 }
        #expect(tap.droppedAfterClose > 0, "닫힌 뒤 도착한 콜백은 버려진다")
    }
}

@Suite struct SystemTapSinkTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func convertsInterleavedTapBufferIntoFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                      channels: 2, interleaved: true)!
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 2, interleaved: false)!
        let url = directory.appendingPathComponent("system.caf")
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        #expect(file.processingFormat != tapFormat, "이 테스트는 포맷이 다를 때를 본다")

        let sink = SystemTapSink()
        sink.open(file: file, from: tapFormat)

        let frames: AVAudioFrameCount = 1024
        let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) * 2 { samples[index] = 0.5 }

        sink.receive(buffer.audioBufferList, format: tapFormat)
        #expect(sink.receivedBuffers == 1)
        #expect(file.length == Int64(frames), "변환 후 프레임이 그대로 파일에 들어간다")

        sink.close()
        sink.receive(buffer.audioBufferList, format: tapFormat)
        #expect(sink.receivedBuffers == 1, "닫힌 뒤 도착분은 세지도 쓰지도 않는다")
    }

    @Test func writesMatchingFormatWithoutConversion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("m.caf"),
                                   settings: format.settings)
        let sink = SystemTapSink()
        sink.open(file: file, from: file.processingFormat)

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
        buffer.frameLength = 512
        sink.receive(buffer.audioBufferList, format: file.processingFormat)

        #expect(file.length == 512)
    }

    @Test func opensCompressedTrackFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: true)!
        let (url, _) = try SystemAudioTap.openFile(directory: directory, name: "abc-system",
                                                   format: format)
        #expect(url.lastPathComponent == "abc-system.m4a")
    }
}

@Suite struct LiveSystemAudioTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_LIVE_AUDIO"] != nil))
    func capturesPlayedSound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tap = SystemAudioTap(name: "meeting-test-system-audio")
        let url = try tap.start(name: "live-system", in: directory)
        for _ in 0..<2 {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.05", "/System/Library/Sounds/Glass.aiff"]
            try player.run()
            player.waitUntilExit()
        }
        tap.stop()

        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        }
        #expect(peak > 0.001, "재생한 소리가 시스템 트랙에 담겨야 한다 (실측 peak \(peak))")
    }
}
