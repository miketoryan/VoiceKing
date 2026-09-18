import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let bridge = LocalBridgeClient()

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

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

        micButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        micButton.layer.cornerRadius = 16
        micButton.backgroundColor = .systemBlue
        micButton.tintColor = .white
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.titleLabel?.font = .systemFont(ofSize: 18)
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 18)
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let tools = UIStackView(arrangedSubviews: [globeButton, micButton, deleteButton])
        tools.axis = .horizontal
        tools.alignment = .fill
        tools.distribution = .fillEqually
        tools.spacing = 10

        let stack = UIStackView(arrangedSubviews: [statusLabel, tools])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            micButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
    }

    @objc private func toggleRecording() {
        guard hasFullAccess else {
            statusLabel.text = "Enable Allow Full Access for VoiceKey in Settings."
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID) {
            insertLatestTranscription(automatically: false)
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = "Open VoiceKey and start Keyboard Service first."
            micButton.setTitle(" Start Service in App ", for: .normal)
            micButton.backgroundColor = .systemGray
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
                do {
                    try await Task.sleep(for: LocalBridge.keyboardHeartbeatInterval)
                } catch {
                    return
                }
                await self.sendHeartbeat()
            }
        }

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchState()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
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
        do {
            let state = try await bridge.send(.heartbeat)
            apply(state)
        } catch {
            applyConnectionFailure()
        }
    }

    private func fetchState() async {
        guard keyboardVisible else { return }
        do {
            let state = try await bridge.fetchState()
            apply(state)
        } catch {
            applyConnectionFailure()
        }
    }

    private func sendCommand(_ action: BridgeAction, requestID: String?) {
        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await self.bridge.send(action, requestID: requestID)
                self.apply(state)
            } catch {
                self.latestState = .unavailable(
                    "VoiceKey did not respond. Open the app and start Keyboard Service again."
                )
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
            lastError: nil
        )
        refreshUI()
        sendCommand(.startRecording, requestID: requestID)
    }

    private func apply(_ state: BridgeState) {
        if state.serverID == latestState.serverID,
           state.revision < latestState.revision {
            return
        }
        latestState = state
        refreshUI()

        if state.status == .completed {
            insertLatestTranscription()
        }
    }

    private func applyConnectionFailure() {
        guard latestState.status != .recording,
              latestState.status != .transcribing else {
            return
        }
        latestState = .unavailable(
            "Open VoiceKey and start Keyboard Service."
        )
        refreshUI()
    }

    private func refreshUI() {
        guard hasFullAccess else {
            statusLabel.text = "Allow Full Access is required."
            micButton.setTitle(" Enable Full Access ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = "Transcription ready — tap to insert"
            micButton.setTitle(" Insert Result ", for: .normal)
            micButton.backgroundColor = .systemGreen
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = latestState.lastError ?? "Open VoiceKey and start Keyboard Service."
            micButton.setTitle(" Start Service in App ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        switch latestState.status {
        case .idle:
            statusLabel.text = "Ready"
            micButton.setTitle(" 🎙  Speak ", for: .normal)
            micButton.backgroundColor = .systemBlue
        case .starting:
            statusLabel.text = "Connecting to VoiceKey…"
            micButton.setTitle(" Starting… ", for: .normal)
            micButton.backgroundColor = .systemGray
        case .recording:
            statusLabel.text = "Recording… tap again to finish"
            micButton.setTitle(" ⏹  Stop ", for: .normal)
            micButton.backgroundColor = .systemRed
        case .transcribing:
            statusLabel.text = "ChatGPT is transcribing…"
            micButton.setTitle(" Processing… ", for: .normal)
            micButton.backgroundColor = .systemGray
        case .completed:
            statusLabel.text = "The transcription result expired."
            micButton.setTitle(" 🎙  Speak ", for: .normal)
            micButton.backgroundColor = .systemBlue
        case .error:
            statusLabel.text = latestState.lastError ?? "Transcription failed."
            micButton.setTitle(" 🎙  Try Again ", for: .normal)
            micButton.backgroundColor = .systemOrange
        }
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
            lastError: nil
        )
        refreshUI()
        sendCommand(.acknowledgeResult, requestID: requestID)
    }
}
