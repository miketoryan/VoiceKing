import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady = false
    @Published private(set) var statusText = "Idle"
    @Published var lastError: String?

    private let auth: ChatGPTAuthManager
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private let localBridge = LocalBridgeServer()
    private let serverID = UUID().uuidString

    private var stateRevision: UInt64 = 0
    private var activeRecordingURL: URL?
    private var activeRequestID: String?
    private var bridgeStatus: BridgeStatus = .idle
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?
    private var lastKeyboardHeartbeat: Date?
    private var keyboardHasConnected = false
    private var keyboardMonitorTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    init() {
        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email

        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("VoiceKey is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
        } catch {
            lastError = error.localizedDescription
            statusText = "Local keyboard connection failed"
        }
    }

    deinit {
        keyboardMonitorTask?.cancel()
        transcriptionTask?.cancel()
        localBridge.stop()
    }

    func signIn() async {
        lastError = nil
        do {
            try await auth.signIn()
            signedIn = true
            accountEmail = auth.credential?.email
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        stopService()
        auth.signOut()
        signedIn = false
        accountEmail = nil
    }

    func startService() async {
        lastError = nil
        guard signedIn else {
            lastError = "Sign in with ChatGPT first."
            return
        }

        let granted = await AudioService.requestPermission()
        guard granted else {
            lastError = "Microphone permission is required."
            return
        }

        do {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            keyboardMonitorTask?.cancel()
            keyboardMonitorTask = nil

            try audio.enterStandby()
            serviceReady = true
            statusText = "Waiting for VoiceKey keyboard"
            activeRecordingURL = nil
            activeRequestID = nil
            bridgeStatus = .idle
            clearResult()
            lastKeyboardHeartbeat = nil
            keyboardHasConnected = false
            markStateChanged()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func stopService() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
        audio.disarm()
        serviceReady = false
        statusText = "Idle"
        bridgeStatus = .idle
        clearResult()
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false
        markStateChanged()
    }

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            activateMicrophoneForKeyboardIfNeeded()

        case .startRecording:
            activateMicrophoneForKeyboardIfNeeded()
            startRecordingFromKeyboard(requestID: request.requestID)

        case .stopRecording:
            activateMicrophoneForKeyboardIfNeeded()
            beginFinishingRecording(
                expectedRequestID: request.requestID,
                deactivateMicrophoneAfterCapture: false
            )

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)
        }

        return currentBridgeState()
    }

    private func activateMicrophoneForKeyboardIfNeeded() {
        guard serviceReady else { return }

        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true

        guard !audio.isRunning else { return }

        do {
            try audio.arm()
            statusText = "Ready for keyboard dictation"
            lastError = nil
            bridgeError = nil
            markStateChanged()
            startKeyboardMonitor()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    private func startRecordingFromKeyboard(requestID: String?) {
        guard serviceReady, audio.isRunning else {
            publishError(
                "Open VoiceKey and start Keyboard Service first.",
                requestID: requestID
            )
            return
        }
        guard let requestID, !requestID.isEmpty else {
            publishError("VoiceKey received an invalid recording request.")
            return
        }
        guard bridgeStatus != .recording,
              bridgeStatus != .starting,
              bridgeStatus != .transcribing else {
            return
        }

        bridgeStatus = .starting
        activeRequestID = requestID
        clearResult(keepingRequest: true)
        markStateChanged()

        do {
            activeRecordingURL = try audio.beginCapture()
            bridgeStatus = .recording
            statusText = "Recording…"
            markStateChanged()
        } catch {
            publishError(error.localizedDescription, requestID: requestID)
        }
    }

    private func finishRecordingFromKeyboard(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) async {
        guard bridgeStatus == .recording else { return }
        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else { return }

        let capturedURL = audio.endCapture() ?? activeRecordingURL
        activeRecordingURL = nil

        guard let url = capturedURL else {
            publishError("No recording was captured.", requestID: requestID)
            return
        }

        bridgeStatus = .transcribing
        statusText = "Transcribing…"
        markStateChanged()

        if deactivateMicrophoneAfterCapture {
            deactivateMicrophonePreservingResponse()
        }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let text = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: "zh"
            )
            responseText = text
            resultCreatedAt = Date()
            bridgeError = nil
            bridgeStatus = .completed
            statusText = audio.isRunning
                ? "Ready for keyboard dictation"
                : "Keyboard closed. Transcription is ready."
            signedIn = true
            accountEmail = credential.email
            markStateChanged()
        } catch {
            guard !Task.isCancelled else { return }
            publishError(error.localizedDescription, requestID: requestID)
            statusText = "Transcription failed"
        }
    }

    private func beginFinishingRecording(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) {
        guard bridgeStatus == .recording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.finishRecordingFromKeyboard(
                expectedRequestID: expectedRequestID,
                deactivateMicrophoneAfterCapture: deactivateMicrophoneAfterCapture
            )
        }
    }

    private func startKeyboardMonitor() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                guard let self, self.serviceReady else { return }
                guard self.audio.isRunning else { return }
                guard self.keyboardHasConnected,
                      let heartbeat = self.lastKeyboardHeartbeat,
                      Date().timeIntervalSince(heartbeat) >= LocalBridge.keyboardExitGracePeriod else {
                    continue
                }

                if self.bridgeStatus == .recording {
                    self.beginFinishingRecording(
                        expectedRequestID: self.activeRequestID,
                        deactivateMicrophoneAfterCapture: true
                    )
                } else {
                    self.deactivateMicrophonePreservingResponse()
                }
                return
            }
        }
    }

    private func deactivateMicrophonePreservingResponse() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        do {
            try audio.enterStandby()
        } catch {
            publishError(error.localizedDescription)
            stopService()
            return
        }
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false
        markStateChanged()

        switch bridgeStatus {
        case .starting, .idle:
            activeRequestID = nil
            bridgeStatus = .idle
            statusText = "Waiting for VoiceKey keyboard"
        case .recording:
            break
        case .transcribing:
            statusText = "Keyboard closed. Finishing transcription…"
        case .completed:
            statusText = "Keyboard closed. Transcription is ready."
        case .error:
            statusText = "Waiting for VoiceKey keyboard"
        }
    }

    private func acknowledgeResult(requestID: String?) {
        guard requestID == nil || requestID == activeRequestID else { return }
        activeRequestID = nil
        clearResult()
        if bridgeStatus == .completed || bridgeStatus == .error {
            bridgeStatus = .idle
        }
        if serviceReady {
            statusText = audio.isRunning
                ? "Ready for keyboard dictation"
                : "Waiting for VoiceKey keyboard"
        }
        markStateChanged()
    }

    private func clearResult(keepingRequest: Bool = false) {
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        if !keepingRequest {
            activeRequestID = nil
        }
    }

    private func publishError(_ message: String, requestID: String? = nil) {
        if let requestID {
            activeRequestID = requestID
        }
        responseText = nil
        resultCreatedAt = Date()
        bridgeError = message
        bridgeStatus = .error
        lastError = message
        markStateChanged()
    }

    private func currentBridgeState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: stateRevision,
            serviceReady: serviceReady && audio.isRunning,
            status: bridgeStatus,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError
        )
    }

    private func markStateChanged() {
        stateRevision &+= 1
    }
}
