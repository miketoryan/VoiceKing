import AVFoundation
import Foundation

struct ChatGPTTranscriptionService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    func transcribe(
        audioURL: URL,
        credential: ChatGPTAuthManager.Credential,
        language: String?
    ) async throws -> String {
        let boundary = "VoiceKing-\(UUID().uuidString)"
        let optimizedAudioURL = (try? makeOptimizedSpeechFile(audioURL: audioURL)) ?? audioURL
        let multipartURL = try makeMultipartBodyFile(
            audioURL: optimizedAudioURL,
            boundary: boundary,
            language: language
        )
        defer {
            try? FileManager.default.removeItem(at: multipartURL)
            if optimizedAudioURL != audioURL {
                try? FileManager.default.removeItem(at: optimizedAudioURL)
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("Codex Desktop/26.707.8479.0 (Windows; x64)", forHTTPHeaderField: "User-Agent")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: multipartURL)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw TranscriptionError.authenticationExpired
            case 429:
                throw TranscriptionError.rateLimited
            default:
                throw TranscriptionError.http(http.statusCode, detail)
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.noText
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeMultipartBodyFile(
        audioURL: URL,
        boundary: String,
        language: String?
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceking-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }

            if let language, !language.isEmpty {
                try output.write(contentsOf: Data(
                    ("--\(boundary)\r\n" +
                     "Content-Disposition: form-data; name=\"language\"\r\n\r\n" +
                     "\(language)\r\n").utf8
                ))
            }

            try output.write(contentsOf: Data(
                ("--\(boundary)\r\n" +
                 "Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n" +
                 "Content-Type: audio/wav\r\n\r\n").utf8
            ))

            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }

            try output.write(contentsOf: Data(
                "\r\n--\(boundary)--\r\n".utf8
            ))
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        return bodyURL
    }

    private func makeOptimizedSpeechFile(audioURL: URL) throws -> URL {
        let inputFile = try AVAudioFile(forReading: audioURL)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceking-speech-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        let inputCapacity: AVAudioFrameCount = 4_096
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputCapacity
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = max(
            AVAudioFrameCount(1_024),
            AVAudioFrameCount(ceil(Double(inputCapacity) * ratio)) + 64
        )

        var reachedEnd = false
        var pendingReadError: Error?

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    inputBuffer.frameLength = 0
                    try inputFile.read(
                        into: inputBuffer,
                        frameCount: inputCapacity
                    )
                } catch {
                    pendingReadError = error
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                guard inputBuffer.frameLength > 0 else {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let pendingReadError {
                throw pendingReadError
            }
            if let conversionError {
                throw conversionError
            }
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
            if status == .endOfStream {
                break
            }
        }

        return outputURL
    }

    enum TranscriptionError: LocalizedError {
        case invalidResponse
        case authenticationExpired
        case rateLimited
        case http(Int, String)
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Invalid transcription response."
            case .authenticationExpired: "ChatGPT authorization expired. Open VoiceKing and sign in again."
            case .rateLimited: "ChatGPT transcription is temporarily rate limited."
            case .http(let status, let detail):
                detail.isEmpty ? "Transcription failed (HTTP \(status))." : "Transcription failed (HTTP \(status)): \(detail)"
            case .noText: "No speech was recognized."
            }
        }
    }
}
