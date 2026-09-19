import KeyboardKitHostPlugin
import SwiftUI
import UIKit

@MainActor
private final class KeyboardURLLauncher: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    @Published var request: Request?

    func open(_ url: URL) {
        request = Request(url: url)
    }
}

private struct KeyboardURLLauncherView: View {
    @ObservedObject var launcher: KeyboardURLLauncher
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onChange(of: launcher.request) { _, request in
                guard let request else { return }
                openURL(request.url)
                launcher.request = nil
            }
    }
}

final class KeyboardViewController: UIInputViewController {
    private let brandLabel = UILabel()
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智能", "原文"])
    private let languageButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let bridge = LocalBridgeClient()
    private let urlLauncher = KeyboardURLLauncher()
    private var urlLauncherHost: UIHostingController<KeyboardURLLauncherView>?

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var pendingAutoRecordingAfterLaunch = false
    private var resolvedHostBundleIdentifier: String?
    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var hostResolutionTask: Task<Void, Never>?

    private enum Defaults {
        static let transcriptionMode = "voiceking.transcription-mode"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        resolveHostApplicationInAdvance()
        startBridgeTasks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardVisible = false
        mayAutoInsert = false
        stopBridgeTasks()
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if latestState.status == .transcribing {
            mayAutoInsert = false
        }
    }

    deinit {
        heartbeatTask?.cancel()
        pollingTask?.cancel()
        commandTask?.cancel()
        hostResolutionTask?.cancel()
    }

    private func configureUI() {
        view.backgroundColor = .secondarySystemBackground

        brandLabel.text = "VK  VoiceKing"
        brandLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        brandLabel.textColor = .label

        modeControl.selectedSegmentIndex = selectedMode == .smart ? 0 : 1
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        languageButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        languageButton.layer.cornerRadius = 14
        languageButton.backgroundColor = .tertiarySystemFill
        languageButton.setTitleColor(.label, for: .normal)
        languageButton.addTarget(self, action: #selector(toggleLanguage), for: .touchUpInside)

        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        micButton.layer.cornerRadius = 27
        micButton.backgroundColor = .label
        micButton.tintColor = .white
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

        returnButton.setTitle("换行", for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        returnButton.setTitleColor(.label, for: .normal)
        returnButton.backgroundColor = .tertiarySystemFill
        returnButton.layer.cornerRadius = 18
        returnButton.addTarget(self, action: #selector(insertNewline), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topBar = UIStackView(arrangedSubviews: [brandLabel, topSpacer, modeControl, languageButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8

        let micLeftSpacer = UIView()
        let micRightSpacer = UIView()
        let micRow = UIStackView(arrangedSubviews: [micLeftSpacer, micButton, micRightSpacer])
        micRow.axis = .horizontal
        micRow.alignment = .center
        micRow.distribution = .equalCentering

        let tools = UIStackView(arrangedSubviews: [globeButton, returnButton, deleteButton])
        tools.axis = .horizontal
        tools.alignment = .center
        tools.distribution = .equalCentering

        globeButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 86).isActive = true
        returnButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        modeControl.widthAnchor.constraint(equalToConstant: 112).isActive = true
        languageButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        languageButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let stack = UIStackView(arrangedSubviews: [topBar, statusLabel, micRow, tools])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let launcherHost = UIHostingController(
            rootView: KeyboardURLLauncherView(launcher: urlLauncher)
        )
        addChild(launcherHost)
        launcherHost.view.backgroundColor = .clear
        launcherHost.view.isUserInteractionEnabled = false
        launcherHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launcherHost.view)
        launcherHost.didMove(toParent: self)
        urlLauncherHost = launcherHost

        let height = view.heightAnchor.constraint(equalToConstant: 226)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            micButton.widthAnchor.constraint(equalToConstant: 92),
            micButton.heightAnchor.constraint(equalToConstant: 54),
            launcherHost.view.widthAnchor.constraint(equalToConstant: 1),
            launcherHost.view.heightAnchor.constraint(equalToConstant: 1),
            launcherHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launcherHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
    }

    @objc private func modeChanged() {
        let mode: TranscriptionMode = modeControl.selectedSegmentIndex == 1
            ? .verbatim
            : .smart
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.transcriptionMode)
    }

    @objc private func toggleLanguage() {
        let language: KeyboardLanguage = latestState.preferredKeyboardLanguage == .chinese
            ? .english
            : .chinese
        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: latestState.serviceReady,
            microphoneReady: latestState.microphoneReady,
            status: latestState.status,
            requestID: latestState.requestID,
            transcribedText: latestState.transcribedText,
            resultCreatedAt: latestState.resultCreatedAt,
            lastError: latestState.lastError,
            preferredKeyboardLanguage: language
        )
        refreshUI()
        sendCommand(.setKeyboardLanguage, requestID: nil, language: language)
    }

    @objc private func toggleRecording() {
        guard hasFullAccess else {
            statusLabel.text = "请在系统设置中开启“允许完全访问”"
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID) {
            insertLatestTranscription(automatically: false)
            return
        }

        guard latestState.serviceReady else {
            launchVoiceKingAndResumeRecording()
            return
        }

        // iOS keyboard extensions cannot record directly. If the containing
        // app's microphone engine is not already active, briefly bring
        // VoiceKing to the foreground, start capture, and return to the host.
        if !latestState.microphoneReady {
            launchVoiceKingAndResumeRecording()
            return
        }

        switch latestState.status {
        case .recording:
            mayAutoInsert = true
            sendCommand(.stopRecording, requestID: latestState.requestID ?? currentRequestID)
        case .starting, .transcribing:
            break
        default:
            startRecordingRequest()
        }
    }

    @objc private func nextKeyboard() {
        keyboardVisible = false
        mayAutoInsert = false
        stopBridgeTasks()
        advanceToNextInputMode()
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func insertNewline() {
        textDocumentProxy.insertText("\n")
    }

    private func startBridgeTasks() {
        stopBridgeTasks()

        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendHeartbeat()
            while !Task.isCancelled {
                do { try await Task.sleep(for: LocalBridge.keyboardHeartbeatInterval) }
                catch { return }
                await self.sendHeartbeat()
            }
        }

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchState()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                await self.fetchState()
            }
        }
    }

    private func stopBridgeTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func sendHeartbeat() async {
        guard keyboardVisible else { return }
        do { apply(try await bridge.send(.heartbeat)) }
        catch { applyConnectionFailure() }
    }

    private func fetchState() async {
        guard keyboardVisible else { return }
        do { apply(try await bridge.fetchState()) }
        catch { applyConnectionFailure() }
    }

    private func sendCommand(
        _ action: BridgeAction,
        requestID: String?,
        mode: TranscriptionMode? = nil,
        language: KeyboardLanguage? = nil
    ) {
        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.apply(
                    try await self.bridge.send(
                        action,
                        requestID: requestID,
                        mode: mode,
                        language: language
                    )
                )
            } catch {
                self.latestState = .unavailable("VoiceKing 未响应，点语音按钮可自动唤醒")
                self.refreshUI()
            }
        }
    }

    private func startRecordingRequest(requestID suppliedRequestID: String? = nil) {
        let requestID = suppliedRequestID ?? UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: true,
            microphoneReady: latestState.microphoneReady,
            status: .starting,
            requestID: requestID,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: nil,
            preferredKeyboardLanguage: latestState.preferredKeyboardLanguage
        )
        refreshUI()
        sendCommand(
            .startRecording,
            requestID: requestID,
            mode: selectedMode,
            language: latestState.preferredKeyboardLanguage
        )
    }

    private func apply(_ state: BridgeState) {
        if state.serverID == latestState.serverID,
           state.revision < latestState.revision { return }
        latestState = state
        refreshUI()

        if pendingAutoRecordingAfterLaunch,
           state.serviceReady {
            if state.status == .recording,
               let requestID = state.requestID,
               requestID == currentRequestID {
                pendingAutoRecordingAfterLaunch = false
                mayAutoInsert = true
                return
            }

            if state.status == .idle, state.microphoneReady {
                pendingAutoRecordingAfterLaunch = false
                startRecordingRequest(requestID: currentRequestID)
                return
            }
        }

        if state.status == .completed { insertLatestTranscription() }
    }

    private func applyConnectionFailure() {
        guard latestState.status != .recording,
              latestState.status != .transcribing else { return }
        latestState = .unavailable("服务休眠，点语音按钮可自动唤醒")
        refreshUI()
    }

    private func refreshUI() {
        languageButton.setTitle(
            latestState.preferredKeyboardLanguage == .chinese ? "中" : "EN",
            for: .normal
        )

        guard hasFullAccess else {
            statusLabel.text = "需要允许完全访问"
            applyMicStyle(title: "开启完全访问", symbol: "mic.slash", color: .systemGray)
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = "识别完成，点击插入"
            applyMicStyle(title: "插入识别结果", symbol: "text.badge.checkmark", color: .systemGreen)
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = latestState.lastError ?? "点击说话 · 自动唤醒 VoiceKing"
            applyMicStyle(title: "唤醒并开始说话", symbol: "mic.fill", color: .label)
            return
        }

        let languageName = latestState.preferredKeyboardLanguage == .chinese
            ? "中文识别"
            : "English Recognition"

        switch latestState.status {
        case .idle:
            statusLabel.text = latestState.microphoneReady
                ? "\(languageName) · 点击说话"
                : "\(languageName) · 点击说话（自动唤醒）"
            applyMicStyle(title: "开始说话", symbol: "mic.fill", color: .label)
        case .starting:
            statusLabel.text = "正在打开麦克风…"
            applyMicStyle(title: "正在启动…", symbol: "mic", color: .systemGray)
        case .recording:
            statusLabel.text = "录音中 · 再点一次结束"
            applyMicStyle(title: "结束录音", symbol: "waveform", color: .label)
        case .transcribing:
            statusLabel.text = "ChatGPT 正在识别…"
            applyMicStyle(title: "正在处理…", symbol: "waveform", color: .systemGray)
        case .completed:
            statusLabel.text = "识别结果已过期"
            applyMicStyle(
                title: "开始说话",
                symbol: "mic.fill",
                color: .label
            )
        case .error:
            statusLabel.text = latestState.lastError ?? "识别失败"
            applyMicStyle(title: "重试", symbol: "mic", color: .systemOrange)
        }
    }

    private func applyMicStyle(title: String, symbol: String, color: UIColor) {
        micButton.setTitle(nil, for: .normal)
        micButton.setImage(UIImage(systemName: symbol), for: .normal)
        micButton.backgroundColor = color
        micButton.tintColor = color == .label ? .systemBackground : .white
        micButton.accessibilityLabel = title
    }

    private func insertLatestTranscription(automatically: Bool = true) {
        guard let requestID = latestState.requestID,
              latestState.isFreshResponse(for: requestID) else {
            refreshUI()
            return
        }

        if automatically {
            guard keyboardVisible,
                  mayAutoInsert,
                  currentRequestID == requestID else {
                refreshUI()
                return
            }
        }

        guard let text = latestState.transcribedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshUI()
            return
        }

        textDocumentProxy.insertText(text)
        currentRequestID = nil
        mayAutoInsert = false
        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: latestState.serviceReady,
            microphoneReady: latestState.microphoneReady,
            status: .idle,
            requestID: nil,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: nil,
            preferredKeyboardLanguage: latestState.preferredKeyboardLanguage
        )
        refreshUI()
        sendCommand(.acknowledgeResult, requestID: requestID)
    }

    private var selectedMode: TranscriptionMode {
        guard let rawValue = UserDefaults.standard.string(forKey: Defaults.transcriptionMode),
              let mode = TranscriptionMode(rawValue: rawValue) else { return .smart }
        return mode
    }

    private func resolveHostApplicationInAdvance() {
        guard resolvedHostBundleIdentifier == nil else { return }
        hostResolutionTask?.cancel()
        hostResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bundleIdentifier = await self.resolveHostBundleIdentifier()
            guard !Task.isCancelled else { return }
            self.resolvedHostBundleIdentifier = bundleIdentifier
        }
    }

    private func launchVoiceKingAndResumeRecording() {
        guard !pendingAutoRecordingAfterLaunch else { return }

        let requestID = UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        pendingAutoRecordingAfterLaunch = true
        statusLabel.text = "正在启动 VoiceKing…"
        applyMicStyle(title: "正在打开 App…", symbol: "mic", color: .systemGray)

        if let resolvedHostBundleIdentifier {
            openVoiceKing(
                returningTo: resolvedHostBundleIdentifier,
                requestID: requestID
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let hostBundleIdentifier = await self.resolveHostBundleIdentifier()
            self.resolvedHostBundleIdentifier = hostBundleIdentifier
            self.openVoiceKing(
                returningTo: hostBundleIdentifier,
                requestID: requestID
            )
        }
    }

    private func openVoiceKing(
        returningTo hostBundleIdentifier: String?,
        requestID: String
    ) {
        var components = URLComponents()
        components.scheme = "voiceking"
        components.host = "start-recording"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: requestID),
            URLQueryItem(name: "mode", value: selectedMode.rawValue),
            URLQueryItem(
                name: "language",
                value: latestState.preferredKeyboardLanguage.rawValue
            )
        ]
        if let hostBundleIdentifier {
            components.queryItems?.append(
                URLQueryItem(name: "returnBundleIdentifier", value: hostBundleIdentifier)
            )
        }

        guard let url = components.url else {
            pendingAutoRecordingAfterLaunch = false
            return
        }

        // SwiftUI's openURL environment is the supported URL handoff path from
        // a custom keyboard. UIKit's NSExtensionContext.open is not reliable
        // for UIInputViewController on recent iOS releases.
        urlLauncher.open(url)

        // Personal-sideload fallback. If SwiftUI has already opened VoiceKing,
        // viewWillDisappear clears keyboardVisible and this path is skipped.
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard let self,
                  self.keyboardVisible,
                  self.pendingAutoRecordingAfterLaunch else { return }

            if !self.openURLViaResponderChain(url) {
                self.pendingAutoRecordingAfterLaunch = false
                self.statusLabel.text = "无法自动打开 VoiceKing，请手动启动服务"
                self.refreshUI()
            }
        }
    }

    private func resolveHostBundleIdentifier() async -> String? {
        try? await pluginHostApplicationResolver(
            controller: self,
            pollingInterval: 0.08,
            timeout: 1.2
        )
    }

    @discardableResult
    private func openURLViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }
}
