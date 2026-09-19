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
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智能整理", "原文模式"])
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let bridge = LocalBridgeClient()
    private let urlLauncher = KeyboardURLLauncher()
    private var urlLauncherHost: UIHostingController<KeyboardURLLauncherView>?

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var pendingAutoRecordingAfterLaunch = false
    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

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
    }

    private func configureUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        modeControl.selectedSegmentIndex = selectedMode == .smart ? 0 : 1
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        micButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        micButton.layer.cornerRadius = 14
        micButton.backgroundColor = .systemBlue
        micButton.tintColor = .white
        micButton.setTitleColor(.white, for: .normal)
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let tools = UIStackView(arrangedSubviews: [globeButton, micButton, deleteButton])
        tools.axis = .horizontal
        tools.alignment = .fill
        tools.distribution = .fillProportionally
        tools.spacing = 10

        globeButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let stack = UIStackView(arrangedSubviews: [modeControl, statusLabel, tools])
        stack.axis = .vertical
        stack.spacing = 10
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

        let height = view.heightAnchor.constraint(equalToConstant: 180)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            micButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
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

    private func startRecordingRequest() {
        let requestID = UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        latestState = BridgeState(
            serverID: latestState.serverID,
            revision: latestState.revision &+ 1,
            serviceReady: true,
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
           state.serviceReady,
           state.status == .idle {
            pendingAutoRecordingAfterLaunch = false
            startRecordingRequest()
            return
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
        guard hasFullAccess else {
            statusLabel.text = "需要允许完全访问"
            applyMicStyle(title: "开启完全访问", color: .systemGray)
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = "识别完成，点击插入"
            applyMicStyle(title: "插入识别结果", color: .systemGreen)
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = latestState.lastError ?? "VoiceKing 服务休眠"
            applyMicStyle(title: "🎙 唤醒并开始说话", color: .systemGray)
            return
        }

        let languageName = latestState.preferredKeyboardLanguage == .chinese
            ? "中文识别"
            : "English Recognition"

        switch latestState.status {
        case .idle:
            statusLabel.text = "\(languageName) · 就绪"
            applyMicStyle(title: "🎙 开始说话", color: .systemBlue)
        case .starting:
            statusLabel.text = "正在连接 VoiceKing…"
            applyMicStyle(title: "正在启动…", color: .systemGray)
        case .recording:
            statusLabel.text = "录音中，再点一次结束"
            applyMicStyle(title: "⏹ 结束录音", color: .systemRed)
        case .transcribing:
            statusLabel.text = "ChatGPT 正在识别…"
            applyMicStyle(title: "正在处理…", color: .systemGray)
        case .completed:
            statusLabel.text = "识别结果已过期"
            applyMicStyle(title: "🎙 开始说话", color: .systemBlue)
        case .error:
            statusLabel.text = latestState.lastError ?? "识别失败"
            applyMicStyle(title: "🎙 重试", color: .systemOrange)
        }
    }

    private func applyMicStyle(title: String, color: UIColor) {
        micButton.setTitle(title, for: .normal)
        micButton.backgroundColor = color
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

    private func launchVoiceKingAndResumeRecording() {
        guard !pendingAutoRecordingAfterLaunch else { return }
        pendingAutoRecordingAfterLaunch = true
        statusLabel.text = "正在启动 VoiceKing…"
        applyMicStyle(title: "正在打开 App…", color: .systemGray)

        guard let url = URL(
            string: "voiceking://start-recording?mode=\(selectedMode.rawValue)"
        ) else {
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
