import AVFoundation
import Foundation

final class AudioService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var keepAlivePlayer: AVAudioPlayer?
    private var outputFile: AVAudioFile?
    private var currentURL: URL?
    private var tapInstalled = false

    private(set) var isArmed = false

    var isRunning: Bool {
        isArmed && engine.isRunning
    }

    var isKeepingAlive: Bool {
        keepAlivePlayer?.isPlaying == true
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func arm() throws {
        guard !isRunning else { return }

        stopKeepAlive()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.noInput
        }

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        isArmed = true
    }

    func enterStandby() throws {
        stopCaptureEngine()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try session.setActive(true)

        if keepAlivePlayer == nil {
            let player = try AVAudioPlayer(data: Self.silentWAVData)
            player.numberOfLoops = -1
            player.volume = 1
            player.prepareToPlay()
            keepAlivePlayer = player
        }

        guard keepAlivePlayer?.play() == true else {
            throw AudioError.keepAliveFailed
        }
    }

    func beginCapture() throws -> URL {
        guard isArmed, engine.isRunning else { throw AudioError.notArmed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceking-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let format = engine.inputNode.inputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.lock()
        outputFile = file
        currentURL = url
        lock.unlock()

        return url
    }

    func endCapture() -> URL? {
        lock.lock()
        outputFile = nil
        let url = currentURL
        currentURL = nil
        lock.unlock()
        return url
    }

    func disarm() {
        stopCaptureEngine()
        stopKeepAlive()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopCaptureEngine() {
        lock.lock()
        outputFile = nil
        currentURL = nil
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        isArmed = false
    }

    private func stopKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer?.currentTime = 0
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = outputFile
        if let file {
            try? file.write(from: buffer)
        }
        lock.unlock()
    }

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds: UInt32 = 1
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * UInt32(channels) * bytesPerSample * seconds
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()

    enum AudioError: LocalizedError {
        case noInput
        case notArmed
        case keepAliveFailed

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .notArmed: "Start the VoiceKing keyboard service first."
            case .keepAliveFailed: "VoiceKing could not keep its background service active."
            }
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
