import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady = false
    @Published private(set) var statusText = "Idle"
    @Published var lastError: String?
    @Published var preferredKeyboardLanguage: KeyboardLanguage {
        didSet {
            UserDefaults.standard.set(
                preferredKeyboardLanguage.rawValue,
                forKey: Defaults.keyboardLanguage
            )
            markStateChanged()
        }
    }

    private let auth: ChatGPTAuthManager
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private let cleanupService = ChatGPTCleanupService()
    private let localBridge = LocalBridgeServer()
    private let serverID = UUID().uuidString

    private var stateRevision: UInt64 = 0
    private var activeRecordingURL: URL?
    private var activeRequestID: String?
    private var activeTranscriptionMode: TranscriptionMode = .smart
    private var activeRecognitionLanguage: KeyboardLanguage = .chinese
    private var bridgeStatus: BridgeStatus = .idle
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?
    private var lastKeyboardHeartbeat: Date?
    private var keyboardHasConnected = false
    private var keyboardMonitorTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var audioActivationTask: Task<Bool, Never>?

    private enum Defaults {
        static let keyboardLanguage = "voiceking.keyboard-language"
    }

    init() {
        preferredKeyboardLanguage = KeyboardLanguage(
            rawValue: UserDefaults.standard.string(forKey: Defaults.keyboardLanguage) ?? ""
        ) ?? .chinese
        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email

        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("VoiceKing is not running.")
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
        audioActivationTask?.cancel()
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
        await startService(armingMicrophoneBeforeReturn: false)
    }

    private func startService(armingMicrophoneBeforeReturn: Bool) async {
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
            audioActivationTask?.cancel()
            audioActivationTask = nil

            try await performAudioOperationWithRetry {
                if armingMicrophoneBeforeReturn {
                    try audio.arm()
                } else {
                    try audio.enterStandby()
                }
            }
            serviceReady = true
            statusText = armingMicrophoneBeforeReturn
                ? "Ready for keyboard dictation"
                : "Waiting for VoiceKing keyboard"
            activeRecordingURL = nil
            activeRequestID = nil
            bridgeStatus = .idle
            bridgeError = nil
            clearResult()
            lastKeyboardHeartbeat = nil
            keyboardHasConnected = false
            markStateChanged()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "voiceking",
              url.host?.lowercased() == "start-recording" else {
            return
        }

        let returnBundleIdentifier = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: {
            $0.name == "returnBundleIdentifier"
        })?.value

        // Prepare the microphone while VoiceKing is in the foreground. Waiting
        // until the keyboard reappears creates an AVAudioSession race during
        // the app-to-keyboard transition (OSStatus !int / 560557684).
        await startService(armingMicrophoneBeforeReturn: true)
        guard serviceReady else { return }

        try? await Task.sleep(for: .milliseconds(500))
        if let returnBundleIdentifier,
           openHostApplication(bundleIdentifier: returnBundleIdentifier) {
            return
        }

        statusText = "Microphone ready — return to the previous app"
        markStateChanged()
    }

    func stopService() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioActivationTask?.cancel()
        audioActivationTask = nil

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
            _ = await activateMicrophoneForKeyboardIfNeeded()

        case .startRecording:
            if await activateMicrophoneForKeyboardIfNeeded() {
                startRecordingFromKeyboard(
                    requestID: request.requestID,
                    mode: request.mode ?? .smart,
                    language: request.language ?? preferredKeyboardLanguage
                )
            }

        case .stopRecording:
            if await activateMicrophoneForKeyboardIfNeeded() {
                beginFinishingRecording(
                    expectedRequestID: request.requestID,
                    deactivateMicrophoneAfterCapture: false
                )
            }

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)

        case .setKeyboardLanguage:
            if let language = request.language {
                preferredKeyboardLanguage = language
            }
        }

        return currentBridgeState()
    }

    private func activateMicrophoneForKeyboardIfNeeded() async -> Bool {
        guard serviceReady else { return false }

        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true

        if audio.isRunning {
            startKeyboardMonitor()
            return true
        }

        if let audioActivationTask {
            return await audioActivationTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.performAudioOperationWithRetry {
                    try self.audio.arm()
                }
                guard self.serviceReady else {
                    self.audio.disarm()
                    return false
                }
                self.statusText = "Ready for keyboard dictation"
                self.lastError = nil
                self.bridgeError = nil
                self.markStateChanged()
                self.startKeyboardMonitor()
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                self.publishError(error.localizedDescription)
                return false
            }
        }
        audioActivationTask = task
        let activated = await task.value
        audioActivationTask = nil
        return activated
    }

    private func performAudioOperationWithRetry(
        _ operation: () throws -> Void
    ) async throws {
        var retry = 0
        while true {
            do {
                try operation()
                return
            } catch {
                guard Self.isTransientAudioSessionError(error), retry < 4 else {
                    throw error
                }
                retry += 1
                statusText = "Waiting for the microphone…"
                try await Task.sleep(for: .milliseconds(150 * retry))
            }
        }
    }

    private static func isTransientAudioSessionError(_ error: Error) -> Bool {
        // AVAudioSession.ErrorCode.cannotInterruptOthers is the four-character
        // OSStatus "!int". It commonly occurs for a brief moment while iOS is
        // moving from the host app to a custom keyboard.
        (error as NSError).code == 560_557_684
    }

    private func startRecordingFromKeyboard(
        requestID: String?,
        mode: TranscriptionMode,
        language: KeyboardLanguage
    ) {
        guard serviceReady, audio.isRunning else {
            publishError(
                "Open VoiceKing and start Keyboard Service first.",
                requestID: requestID
            )
            return
        }
        guard let requestID, !requestID.isEmpty else {
            publishError("VoiceKing received an invalid recording request.")
            return
        }
        guard bridgeStatus != .recording,
              bridgeStatus != .starting,
              bridgeStatus != .transcribing else {
            return
        }

        bridgeStatus = .starting
        activeRequestID = requestID
        activeTranscriptionMode = mode
        activeRecognitionLanguage = language
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
        statusText = activeTranscriptionMode == .smart
            ? "Transcribing and organizing…"
            : "Transcribing…"
        markStateChanged()

        if deactivateMicrophoneAfterCapture {
            deactivateMicrophonePreservingResponse()
        }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let rawText = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: activeRecognitionLanguage == .chinese ? "zh" : "en"
            )
            let text: String
            if activeTranscriptionMode == .smart {
                do {
                    text = try await cleanupService.clean(
                        transcript: rawText,
                        credential: credential
                    )
                } catch {
                    // Never lose a valid transcription because the optional
                    // cleanup pass is temporarily unavailable.
                    text = rawText
                }
            } else {
                text = rawText
            }
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
            statusText = "Waiting for VoiceKing keyboard"
        case .recording:
            break
        case .transcribing:
            statusText = "Keyboard closed. Finishing transcription…"
        case .completed:
            statusText = "Keyboard closed. Transcription is ready."
        case .error:
            statusText = "Waiting for VoiceKing keyboard"
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
                : "Waiting for VoiceKing keyboard"
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
            lastError: bridgeError,
            preferredKeyboardLanguage: preferredKeyboardLanguage
        )
    }

    private func markStateChanged() {
        stateRevision &+= 1
    }

    private func openHostApplication(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }

        let defaultWorkspaceSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspaceValue = workspaceClass.perform(defaultWorkspaceSelector),
              let workspace = workspaceValue.takeUnretainedValue() as? NSObject else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector) else { return false }

        typealias OpenApplication = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let implementation = workspace.method(for: openSelector)
        let openApplication = unsafeBitCast(implementation, to: OpenApplication.self)
        return openApplication(workspace, openSelector, bundleIdentifier as NSString)
    }
}
