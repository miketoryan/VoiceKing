import AVFoundation
import Foundation

final class AudioService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var currentURL: URL?
    private var tapInstalled = false
    private var audioSessionIsActive = false
    private var writtenFrameCount: AVAudioFramePosition = 0

    private(set) var isArmed = false

    var isRunning: Bool {
        isArmed && engine.isRunning
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

        let session = AVAudioSession.sharedInstance()
        try prepareCaptureSession(session)

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
        do {
            try engine.start()
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionIsActive = false
            isArmed = false
            throw error
        }
        isArmed = true
    }

    func enterStandby() throws {
        stopCaptureEngine()
        let session = AVAudioSession.sharedInstance()
        if audioSessionIsActive {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionIsActive = false
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
        writtenFrameCount = 0
        lock.unlock()

        return url
    }

    func endCapture() -> URL? {
        lock.lock()
        outputFile = nil
        let url = currentURL
        currentURL = nil
        writtenFrameCount = 0
        lock.unlock()
        return url
    }

    func hasWrittenAudioFrames(minimum: AVAudioFramePosition = 2_048) -> Bool {
        lock.lock()
        let result = outputFile != nil && writtenFrameCount >= minimum
        lock.unlock()
        return result
    }

    func disarm() {
        stopCaptureEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionIsActive = false
    }

    private func prepareCaptureSession(_ session: AVAudioSession) throws {
        let categoryChanged = session.category != .playAndRecord || session.mode != .measurement
        if categoryChanged {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothHFP]
            )
        }
        if !audioSessionIsActive || categoryChanged {
            try session.setActive(true)
            audioSessionIsActive = true
        }
    }

    private func stopCaptureEngine() {
        lock.lock()
        outputFile = nil
        currentURL = nil
        writtenFrameCount = 0
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

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = outputFile
        if let file {
            do {
                try file.write(from: buffer)
                writtenFrameCount += AVAudioFramePosition(buffer.frameLength)
            } catch {
                // A capture with no successfully written PCM frames is treated
                // as a failed background start by the app model.
            }
        }
        lock.unlock()
    }

    enum AudioError: LocalizedError {
        case noInput
        case notArmed

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .notArmed: "Start the VoiceKing keyboard service first."
            }
        }
    }
}
