import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var handoffActive = false
    @Published var lastError: String?
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            UserDefaults.standard.set(
                interfaceLanguage.rawValue,
                forKey: Defaults.interfaceLanguage
            )
            refreshStatusText()
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
        static let interfaceLanguage = "voiceking.interface-language"
    }

    init() {
        interfaceLanguage = InterfaceLanguage(
            rawValue: UserDefaults.standard.string(forKey: Defaults.interfaceLanguage) ?? ""
        ) ?? .chinese


        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email
        self.statusText = interfaceLanguage.text(chinese: "空闲", english: "Idle")


        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("VoiceKing is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
        } catch {
            lastError = error.localizedDescription
            statusText = ui("键盘本地连接失败", "Local keyboard connection failed")
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
            await startService()
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
        // Keep the local bridge available with the microphone off. When the
        // keyboard needs audio, VoiceKing briefly wakes in the foreground,
        // starts capture, and immediately returns to the previous app.
        _ = await startService(armingMicrophoneBeforeReturn: false)
    }


    @discardableResult
    private func startService(armingMicrophoneBeforeReturn: Bool) async -> Bool {
        // Never let a stale ready flag from an earlier background session make
        // a failed microphone restart look successful.
        serviceReady = false
        lastError = nil
        markStateChanged()

        guard signedIn else {
            lastError = "Sign in with ChatGPT first."
            return false
        }

        let granted = await AudioService.requestPermission()
        guard granted else {
            lastError = "Microphone permission is required."
            return false
        }

        do {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            keyboardMonitorTask?.cancel()
            keyboardMonitorTask = nil
            audioActivationTask?.cancel()
            audioActivationTask = nil

            // A previous request can be abandoned if the keyboard extension is
            // killed during an app handoff. Always clear that capture before a
            // foreground recovery so the new request starts from a clean file.
            if let staleURL = audio.endCapture() ?? activeRecordingURL {
                try? FileManager.default.removeItem(at: staleURL)
            }
            audio.disarm()

            try await performAudioOperationWithRetry {
                if armingMicrophoneBeforeReturn {
                    try audio.arm()
                } else {
                    try prepareStandbyAudio()
                }
            }
            serviceReady = true
            statusText = armingMicrophoneBeforeReturn
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 VoiceKing 键盘", "Waiting for VoiceKing keyboard")
            activeRecordingURL = nil
            activeRequestID = nil
            bridgeStatus = .idle
            bridgeError = nil
            clearResult()
            lastKeyboardHeartbeat = nil
            keyboardHasConnected = false
            markStateChanged()
            return true
        } catch {
            serviceReady = false
            publishError(error.localizedDescription)
            return false
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "voiceking",
              url.host?.lowercased() == "start-recording" else {
            return
        }
        handoffActive = true

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let returnBundleIdentifier = queryItems.first(where: {
            $0.name == "returnBundleIdentifier"
        })?.value
        let requestID = queryItems.first(where: {
            $0.name == "requestID"
        })?.value
        let mode = queryItems.first(where: {
            $0.name == "mode"
        })?.value.flatMap(TranscriptionMode.init(rawValue:)) ?? .smart
        // A warm background process can receive onOpenURL while iOS is still
        // transitioning it through .inactive. Starting AVAudioSession in that
        // window is the real-device regression: the old serviceReady value
        // survives, the restart fails, and VoiceKing immediately returns to the
        // host without recording. Wait for a genuinely active foreground scene.
        guard await waitForApplicationToBecomeActive() else {
            handoffActive = false
            serviceReady = false
            publishError(
                ui(
                    "VoiceKing 未进入前台，请再次点击语音按钮",
                    "VoiceKing did not reach the foreground. Tap the microphone again."
                ),
                requestID: requestID
            )
            return
        }

        // Start the actual recording file in the foreground. The explicit
        // Boolean prevents an earlier serviceReady value from masking failure.
        let serviceStarted = await startService(armingMicrophoneBeforeReturn: true)
        guard serviceStarted else {
            handoffActive = false
            return
        }

        // Establish a ten-second lease before returning to the host. An older
        // keyboard extension may still be resident after a sideload update. If
        // it never reconnects, the microphone monitor must still shut down the
        // real input engine instead of waiting forever for its first heartbeat.
        noteKeyboardHeartbeat()

        guard let requestID, !requestID.isEmpty else {
            handoffActive = false
            publishError("VoiceKing received an invalid recording request.")
            return
        }

        await startRecordingFromKeyboard(
            requestID: requestID,
            mode: mode
        )

        // Never auto-return on a superficial engine start. Only real PCM for
        // this exact request proves that VoiceKing is ready in the background.
        guard bridgeStatus == .recording,
              activeRequestID == requestID,
              audio.hasWrittenAudioFrames() else {
            handoffActive = false
            return
        }

        // Return as soon as capture is confirmed. A long artificial delay makes
        // the app flash much more visibly than Typeless.
        try? await Task.sleep(for: .milliseconds(120))
        if let returnBundleIdentifier,
           openHostApplication(bundleIdentifier: returnBundleIdentifier) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.handoffActive = false
            }
            return
        }

        handoffActive = false
        statusText = returnBundleIdentifier == nil
            ? ui("未识别原输入 App，请手动返回", "Could not identify the previous app. Return manually.")
            : ui("系统未允许自动返回，请手动返回", "iOS blocked automatic return. Return manually.")
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
        handoffActive = false
        serviceReady = false
        statusText = ui("空闲", "Idle")
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
            noteKeyboardHeartbeat()

        case .keyboardHidden:
            noteKeyboardExit()

        case .startRecording:
            noteKeyboardHeartbeat()

            // Once the input engine has gone cold, iOS does not reliably allow
            // a background app to reactivate microphone capture. Do not accept
            // AVAudioEngine's superficial "running" state as a usable start;
            // tell the keyboard to wake VoiceKing in the foreground instead.
            if !audio.isRunning,
               UIApplication.shared.applicationState != .active {
                publishError(
                    ui(
                        "麦克风已休眠，正在唤醒 VoiceKing",
                        "The microphone is asleep. Waking VoiceKing."
                    ),
                    requestID: request.requestID
                )
            } else if await activateMicrophoneForRecording() {
                await startRecordingFromKeyboard(
                    requestID: request.requestID,
                    mode: request.mode ?? .smart
                )
            }

        case .stopRecording:
            noteKeyboardHeartbeat()
            beginFinishingRecording(
                expectedRequestID: request.requestID,
                deactivateMicrophoneAfterCapture: false
            )

        case .recoverStalledRecording:
            noteKeyboardHeartbeat()
            await recoverStalledRecording(expectedRequestID: request.requestID)

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)

        }

        return currentBridgeState()
    }

    private func noteKeyboardHeartbeat() {
        guard serviceReady else { return }
        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true
    }

    private func noteKeyboardExit() {
        guard serviceReady else { return }
        // Use the exit time as the final lease timestamp. The existing monitor
        // then performs the same delayed shutdown used for a missed heartbeat.
        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true
        if audio.isRunning {
            startKeyboardMonitor()
        }
    }

    private func activateMicrophoneForRecording() async -> Bool {
        guard serviceReady else { return false }

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
                guard !Task.isCancelled else {
                    self.audio.disarm()
                    return false
                }
                guard self.serviceReady else {
                    self.audio.disarm()
                    return false
                }
                self.statusText = self.ui("已准备好语音输入", "Ready for keyboard dictation")
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
                statusText = ui("正在等待麦克风…", "Waiting for the microphone…")
                try await Task.sleep(for: .milliseconds(150 * retry))
            }
        }
    }

    private static func isTransientAudioSessionError(_ error: Error) -> Bool {
        // iOS can briefly reject an audio transition while moving between the
        // host app and keyboard extension. Retry the known transient
        // "cannot interrupt others" error and CoreAudio's unspecified 'what'
        // error seen on real-device background microphone startup.
        let code = (error as NSError).code
        return code == 560_557_684 || code == 2_003_329_396
    }

    private func startRecordingFromKeyboard(
        requestID: String?,
        mode: TranscriptionMode
    ) async {
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

        // A keyboard process can be suspended while the app remains alive.
        // If that leaves an old start/recording request behind, a new tap must
        // replace it instead of being ignored forever. Repeating the same
        // request is idempotent; transcription is never interrupted.
        if bridgeStatus == .recording || bridgeStatus == .starting {
            guard activeRequestID != requestID else { return }
            discardActiveCapture()
        }
        guard bridgeStatus != .transcribing else {
            return
        }

        bridgeStatus = .starting
        activeRequestID = requestID
        activeTranscriptionMode = mode
        clearResult(keepingRequest: true)
        markStateChanged()

        do {
            activeRecordingURL = try audio.beginCapture()

            // AVAudioEngine can report `isRunning` and light iOS's microphone
            // indicator even though a background start delivers no input
            // buffers. Only report recording after PCM frames reach the file.
            let captureConfirmed = await waitForCapturedAudio(
                requestID: requestID,
                timeout: .milliseconds(900)
            )
            guard captureConfirmed else {
                guard activeRequestID == requestID,
                      bridgeStatus == .starting else { return }
                discardActiveCapture()
                audio.disarm()
                publishError(
                    ui(
                        "后台麦克风未产生音频，正在切换到前台启动",
                        "Background microphone produced no audio. Waking VoiceKing."
                    ),
                    requestID: requestID
                )
                return
            }

            bridgeStatus = .recording
            statusText = ui("录音中…", "Recording…")
            startKeyboardMonitor()
            markStateChanged()
        } catch {
            publishError(error.localizedDescription, requestID: requestID)
        }
    }

    private func waitForCapturedAudio(
        requestID: String,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            guard serviceReady,
                  activeRequestID == requestID,
                  bridgeStatus == .starting else { return false }
            if audio.hasWrittenAudioFrames() { return true }
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { return false }
        }
        return audio.hasWrittenAudioFrames()
    }

    private func recoverStalledRecording(expectedRequestID: String?) async {
        guard bridgeStatus != .transcribing,
              bridgeStatus != .completed else { return }
        guard expectedRequestID == nil
                || activeRequestID == nil
                || activeRequestID == expectedRequestID else { return }

        let pendingActivation = audioActivationTask
        pendingActivation?.cancel()
        if let pendingActivation {
            _ = await pendingActivation.value
        }
        audioActivationTask = nil
        discardActiveCapture()
        audio.disarm()
        bridgeStatus = .idle
        bridgeError = nil
        lastError = nil
        clearResult()
        statusText = ui("等待重新启动语音输入", "Waiting to restart dictation")
        markStateChanged()
    }

    private func discardActiveCapture() {
        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
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
            ? ui("正在识别并智能整理…", "Transcribing and organizing…")
            : ui("正在识别…", "Transcribing…")
        markStateChanged()

        if deactivateMicrophoneAfterCapture {
            do {
                try prepareStandbyAudio()
            } catch {
                publishError(error.localizedDescription, requestID: requestID)
                try? FileManager.default.removeItem(at: url)
                return
            }
        }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let rawText = try await transcriber.transcribe(
                audioURL: url,
                credential: credential
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
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("键盘已关闭，识别结果已就绪", "Keyboard closed. Transcription is ready.")
            signedIn = true
            accountEmail = credential.email
            markStateChanged()
        } catch {
            guard !Task.isCancelled else { return }
            publishError(error.localizedDescription, requestID: requestID)
            statusText = ui("识别失败", "Transcription failed")
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
            try prepareStandbyAudio()
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
            statusText = ui("等待 VoiceKing 键盘", "Waiting for VoiceKing keyboard")
        case .recording:
            break
        case .transcribing:
            statusText = ui("键盘已关闭，正在完成识别…", "Keyboard closed. Finishing transcription…")
        case .completed:
            statusText = ui("键盘已关闭，识别结果已就绪", "Keyboard closed. Transcription is ready.")
        case .error:
            statusText = ui("等待 VoiceKing 键盘", "Waiting for VoiceKing keyboard")
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
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 VoiceKing 键盘", "Waiting for VoiceKing keyboard")
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
            serviceReady: serviceReady,
            microphoneReady: audio.isRunning,
            status: bridgeStatus,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError,
            interfaceLanguage: interfaceLanguage
        )
    }

    private func prepareStandbyAudio() throws {
        try audio.enterStandby()
    }

    private func ui(_ chinese: String, _ english: String) -> String {
        interfaceLanguage.text(chinese: chinese, english: english)
    }

    private func refreshStatusText() {
        guard serviceReady else {
            statusText = ui("空闲", "Idle")
            return
        }

        switch bridgeStatus {
        case .idle:
            statusText = audio.isRunning
                ? ui("已准备好语音输入", "Ready for keyboard dictation")
                : ui("等待 VoiceKing 键盘", "Waiting for VoiceKing keyboard")
        case .starting:
            statusText = ui("正在打开麦克风…", "Starting microphone…")
        case .recording:
            statusText = ui("录音中…", "Recording…")
        case .transcribing:
            statusText = activeTranscriptionMode == .smart
                ? ui("正在识别并智能整理…", "Transcribing and organizing…")
                : ui("正在识别…", "Transcribing…")
        case .completed:
            statusText = ui("识别结果已就绪", "Transcription is ready")
        case .error:
            statusText = bridgeError ?? ui("识别失败", "Transcription failed")
        }
    }

    private func markStateChanged() {
        stateRevision &+= 1
    }

    private func waitForApplicationToBecomeActive(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while UIApplication.shared.applicationState != .active {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }

        // Let the foreground transition and audio route settle for one short
        // beat before activating AVAudioSession on a previously suspended app.
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            return false
        }
        return UIApplication.shared.applicationState == .active
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

        let legacySelector = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: legacySelector) {
            typealias LegacyOpenApplication = @convention(c) (
                AnyObject,
                Selector,
                NSString
            ) -> Bool
            let implementation = workspace.method(for: legacySelector)
            let openApplication = unsafeBitCast(
                implementation,
                to: LegacyOpenApplication.self
            )
            if openApplication(workspace, legacySelector, bundleIdentifier as NSString) {
                return true
            }
        }

        // iOS 26 also exposes a newer LaunchServices selector. It is used as a
        // personal-sideload fallback when the legacy call refuses the launch.
        let modernSelector = NSSelectorFromString(
            "openApplicationWithBundleIdentifier:configuration:completionHandler:"
        )
        guard workspace.responds(to: modernSelector) else { return false }

        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        typealias ModernOpenApplication = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            AnyObject?,
            Completion
        ) -> Void

        let completion: Completion = { [weak self] success, error in
            guard !success else { return }
            Task { @MainActor in
                self?.handoffActive = false
                self?.statusText = self?.ui(
                    "系统未允许自动返回，请手动返回",
                    "iOS blocked automatic return. Return manually."
                ) ?? "iOS blocked automatic return. Return manually."
                self?.lastError = error?.localizedDescription
                self?.markStateChanged()
            }
        }

        let implementation = workspace.method(for: modernSelector)
        let openApplication = unsafeBitCast(
            implementation,
            to: ModernOpenApplication.self
        )
        openApplication(
            workspace,
            modernSelector,
            bundleIdentifier as NSString,
            nil,
            completion
        )
        return true
    }
}
