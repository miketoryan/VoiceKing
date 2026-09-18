import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智能整理", "原文"])
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let languageButton = UIButton(type: .system)
    private let shiftButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let commaButton = UIButton(type: .system)
    private let periodButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let compositionLabel = UILabel()
    private let candidateScrollView = UIScrollView()
    private let candidateStack = UIStackView()
    private var letterButtons: [UIButton] = []

    private let bridge = LocalBridgeClient()
    private let pinyinEngine = PinyinEngine()
    private let textChecker = UITextChecker()

    private var latestState = BridgeState.unavailable()
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var pendingAutoRecordingAfterLaunch = false
    private var heartbeatTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var dictionaryUpdateTask: Task<Void, Never>?

    private var keyboardLanguage: KeyboardLanguage = .chinese
    private var pinyinBuffer = ""
    private var currentCandidates: [String] = []
    private var englishPartialWord = ""
    private var isShifted = false
    private var supplementaryWords: [String] = []

    private enum Defaults {
        static let transcriptionMode = "voiceking.transcription-mode"
        static let keyboardLanguage = "voiceking.keyboard-language"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboardLanguage = storedKeyboardLanguage
        configureUI()
        updateLanguageUI()
        refreshUI()
        loadSupplementaryLexicon()

        if hasFullAccess {
            dictionaryUpdateTask = Task { @MainActor [weak self] in
                await self?.pinyinEngine.refreshFromNetworkIfNeeded()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        startBridgeTasks()
        refreshCandidates()
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
        if keyboardLanguage == .english {
            updateEnglishCandidates()
        }
    }

    deinit {
        heartbeatTask?.cancel()
        pollingTask?.cancel()
        commandTask?.cancel()
        dictionaryUpdateTask?.cancel()
    }

    private func configureUI() {
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
                : UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
        }

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.75

        modeControl.selectedSegmentIndex = selectedMode == .smart ? 0 : 1
        modeControl.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 11)], for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.widthAnchor.constraint(equalToConstant: 132).isActive = true

        styleSpecialButton(micButton, background: .systemBlue)
        micButton.tintColor = .white
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        micButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let topBar = UIStackView(arrangedSubviews: [modeControl, statusLabel, micButton])
        topBar.axis = .horizontal
        topBar.spacing = 6
        topBar.alignment = .fill
        topBar.heightAnchor.constraint(equalToConstant: 32).isActive = true

        compositionLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        compositionLabel.textColor = .systemBlue
        compositionLabel.textAlignment = .left
        compositionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        candidateStack.axis = .horizontal
        candidateStack.spacing = 4
        candidateStack.alignment = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateScrollView.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScrollView.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScrollView.frameLayoutGuide.heightAnchor)
        ])

        let candidateBar = UIStackView(arrangedSubviews: [compositionLabel, candidateScrollView])
        candidateBar.axis = .horizontal
        candidateBar.spacing = 6
        candidateBar.alignment = .fill
        candidateBar.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let firstRow = makeLetterRow("qwertyuiop")
        let secondRow = makeLetterRow("asdfghjkl")
        let thirdLetters = makeLetterRow("zxcvbnm")

        configureImageButton(shiftButton, systemName: "shift")
        shiftButton.addTarget(self, action: #selector(toggleShift), for: .touchUpInside)
        shiftButton.widthAnchor.constraint(equalToConstant: 42).isActive = true

        configureImageButton(deleteButton, systemName: "delete.left")
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)
        deleteButton.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let thirdRow = UIStackView(arrangedSubviews: [shiftButton, thirdLetters, deleteButton])
        thirdRow.axis = .horizontal
        thirdRow.spacing = 5
        thirdRow.alignment = .fill
        thirdRow.heightAnchor.constraint(equalToConstant: 42).isActive = true

        configureImageButton(globeButton, systemName: "globe")
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        globeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        styleSpecialButton(languageButton)
        languageButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        languageButton.addTarget(self, action: #selector(toggleLanguage), for: .touchUpInside)
        languageButton.widthAnchor.constraint(equalToConstant: 42).isActive = true

        styleKeyButton(commaButton)
        commaButton.addTarget(self, action: #selector(insertComma), for: .touchUpInside)
        commaButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        styleSpecialButton(spaceButton, background: .systemBackground)
        spaceButton.titleLabel?.font = .systemFont(ofSize: 14)
        spaceButton.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)

        styleKeyButton(periodButton)
        periodButton.addTarget(self, action: #selector(insertPeriod), for: .touchUpInside)
        periodButton.widthAnchor.constraint(equalToConstant: 34).isActive = true

        styleSpecialButton(returnButton)
        returnButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        returnButton.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        returnButton.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let bottomRow = UIStackView(arrangedSubviews: [
            globeButton,
            languageButton,
            commaButton,
            spaceButton,
            periodButton,
            returnButton
        ])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 5
        bottomRow.alignment = .fill
        bottomRow.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let root = UIStackView(arrangedSubviews: [
            topBar,
            candidateBar,
            firstRow,
            insetRow(secondRow, horizontal: 14),
            thirdRow,
            bottomRow
        ])
        root.axis = .vertical
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let height = view.heightAnchor.constraint(equalToConstant: 286)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            height
        ])
    }

    private func makeLetterRow(_ letters: String) -> UIStackView {
        let buttons = letters.map { character -> UIButton in
            let button = UIButton(type: .system)
            button.setTitle(String(character), for: .normal)
            button.accessibilityLabel = String(character)
            styleKeyButton(button)
            button.addTarget(self, action: #selector(letterPressed(_:)), for: .touchUpInside)
            letterButtons.append(button)
            return button
        }
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return row
    }

    private func insetRow(_ row: UIView, horizontal: CGFloat) -> UIView {
        let container = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 42)
        ])
        return container
    }

    private func styleKeyButton(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 21)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 5
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.16
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0.5
    }

    private func styleSpecialButton(
        _ button: UIButton,
        background: UIColor = .tertiarySystemFill
    ) {
        button.backgroundColor = background
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 5
    }

    private func configureImageButton(_ button: UIButton, systemName: String) {
        styleSpecialButton(button)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
    }

    @objc private func letterPressed(_ sender: UIButton) {
        guard let title = sender.title(for: .normal), let letter = title.first else { return }
        if keyboardLanguage == .chinese {
            pinyinBuffer.append(letter.lowercased())
            refreshCandidates()
        } else {
            textDocumentProxy.insertText(String(letter))
            if isShifted {
                isShifted = false
                updateLetterCase()
            }
            updateEnglishCandidates()
        }
    }

    @objc private func toggleShift() {
        guard keyboardLanguage == .english else { return }
        isShifted.toggle()
        updateLetterCase()
    }

    @objc private func deleteBackward() {
        if keyboardLanguage == .chinese, !pinyinBuffer.isEmpty {
            pinyinBuffer.removeLast()
            refreshCandidates()
        } else {
            textDocumentProxy.deleteBackward()
            if keyboardLanguage == .english { updateEnglishCandidates() }
        }
    }

    @objc private func insertSpace() {
        if keyboardLanguage == .chinese, !pinyinBuffer.isEmpty {
            if let first = currentCandidates.first {
                commitChineseCandidate(first)
            } else {
                textDocumentProxy.insertText(pinyinBuffer)
                pinyinBuffer = ""
                refreshCandidates()
            }
        } else {
            textDocumentProxy.insertText(" ")
            refreshCandidates()
        }
    }

    @objc private func insertComma() {
        commitPendingCompositionIfNeeded()
        textDocumentProxy.insertText(keyboardLanguage == .chinese ? "，" : ",")
        refreshCandidates()
    }

    @objc private func insertPeriod() {
        commitPendingCompositionIfNeeded()
        textDocumentProxy.insertText(keyboardLanguage == .chinese ? "。" : ".")
        refreshCandidates()
    }

    @objc private func insertReturn() {
        commitPendingCompositionIfNeeded()
        textDocumentProxy.insertText("\n")
        refreshCandidates()
    }

    @objc private func toggleLanguage() {
        if keyboardLanguage == .chinese, !pinyinBuffer.isEmpty {
            textDocumentProxy.insertText(pinyinBuffer)
            pinyinBuffer = ""
        }
        let next: KeyboardLanguage = keyboardLanguage == .chinese ? .english : .chinese
        setKeyboardLanguage(next, notifyApp: true)
    }

    @objc private func candidatePressed(_ sender: UIButton) {
        guard currentCandidates.indices.contains(sender.tag) else { return }
        let candidate = currentCandidates[sender.tag]
        if keyboardLanguage == .chinese {
            commitChineseCandidate(candidate)
        } else {
            for _ in englishPartialWord { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(candidate)
            englishPartialWord = ""
            refreshCandidates()
        }
    }

    private func commitChineseCandidate(_ candidate: String) {
        pinyinEngine.recordSelection(candidate, for: pinyinBuffer)
        textDocumentProxy.insertText(candidate)
        pinyinBuffer = ""
        refreshCandidates()
    }

    private func commitPendingCompositionIfNeeded() {
        guard keyboardLanguage == .chinese, !pinyinBuffer.isEmpty else { return }
        if let first = currentCandidates.first {
            commitChineseCandidate(first)
        } else {
            textDocumentProxy.insertText(pinyinBuffer)
            pinyinBuffer = ""
        }
    }

    private func refreshCandidates() {
        if keyboardLanguage == .chinese {
            compositionLabel.text = pinyinBuffer
            compositionLabel.isHidden = pinyinBuffer.isEmpty
            currentCandidates = pinyinEngine.candidates(for: pinyinBuffer)
            rebuildCandidateButtons()
        } else {
            compositionLabel.text = nil
            compositionLabel.isHidden = true
            updateEnglishCandidates()
        }
    }

    private func updateEnglishCandidates() {
        guard keyboardLanguage == .english else { return }
        englishPartialWord = currentEnglishWord()
        guard englishPartialWord.count >= 2 else {
            currentCandidates = []
            rebuildCandidateButtons()
            return
        }

        let word = englishPartialWord
        let range = NSRange(location: 0, length: (word as NSString).length)
        let userCompletions = supplementaryWords.filter {
            $0.range(of: word, options: [.caseInsensitive, .anchored]) != nil &&
                $0.caseInsensitiveCompare(word) != .orderedSame
        }
        let completions = textChecker.completions(
            forPartialWordRange: range,
            in: word,
            language: "en_US"
        ) ?? []
        let guesses = textChecker.guesses(
            forWordRange: range,
            in: word,
            language: "en_US"
        ) ?? []
        currentCandidates = Array(
            (userCompletions + completions + guesses).uniqued().prefix(10)
        )
        rebuildCandidateButtons()
    }

    private func loadSupplementaryLexicon() {
        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.main.async {
                self?.supplementaryWords = lexicon.entries
                    .map(\.documentText)
                    .filter { !$0.isEmpty }
                    .uniqued()
                if self?.keyboardLanguage == .english {
                    self?.updateEnglishCandidates()
                }
            }
        }
    }

    private func currentEnglishWord() -> String {
        guard let context = textDocumentProxy.documentContextBeforeInput else { return "" }
        return String(context.reversed().prefix { character in
            character.isLetter || character == "'"
        }.reversed())
    }

    private func rebuildCandidateButtons() {
        candidateStack.arrangedSubviews.forEach { view in
            candidateStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, candidate) in currentCandidates.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(candidate, for: .normal)
            button.setTitleColor(.label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17)
            button.contentEdgeInsets = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 5
            button.addTarget(self, action: #selector(candidatePressed(_:)), for: .touchUpInside)
            candidateStack.addArrangedSubview(button)
        }
        candidateScrollView.setContentOffset(.zero, animated: false)
    }

    private func updateLanguageUI() {
        languageButton.setTitle(keyboardLanguage == .chinese ? "中" : "EN", for: .normal)
        commaButton.setTitle(keyboardLanguage == .chinese ? "，" : ",", for: .normal)
        periodButton.setTitle(keyboardLanguage == .chinese ? "。" : ".", for: .normal)
        spaceButton.setTitle(keyboardLanguage == .chinese ? "空格" : "space", for: .normal)
        returnButton.setTitle(keyboardLanguage == .chinese ? "换行" : "return", for: .normal)
        shiftButton.alpha = keyboardLanguage == .english ? 1 : 0.35
        updateLetterCase()
        refreshCandidates()
    }

    private func updateLetterCase() {
        for button in letterButtons {
            guard let title = button.title(for: .normal) else { continue }
            let normalized = title.lowercased()
            button.setTitle(
                keyboardLanguage == .english && isShifted
                    ? normalized.uppercased()
                    : normalized,
                for: .normal
            )
        }
        shiftButton.backgroundColor = isShifted ? .systemBlue : .tertiarySystemFill
        shiftButton.tintColor = isShifted ? .white : .label
    }

    private func setKeyboardLanguage(_ language: KeyboardLanguage, notifyApp: Bool) {
        guard language != keyboardLanguage else { return }
        keyboardLanguage = language
        isShifted = false
        UserDefaults.standard.set(language.rawValue, forKey: Defaults.keyboardLanguage)
        updateLanguageUI()
        if notifyApp {
            sendCommand(.setKeyboardLanguage, requestID: nil, language: language)
        }
    }

    @objc private func modeChanged() {
        let mode: TranscriptionMode = modeControl.selectedSegmentIndex == 1
            ? .verbatim
            : .smart
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.transcriptionMode)
    }

    @objc private func toggleRecording() {
        guard hasFullAccess else {
            statusLabel.text = "请为 VoiceKing 开启“允许完全访问”"
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
                self.latestState = .unavailable("VoiceKing 未响应，点麦克风可自动唤醒")
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
            preferredKeyboardLanguage: keyboardLanguage
        )
        refreshUI()
        sendCommand(
            .startRecording,
            requestID: requestID,
            mode: selectedMode,
            language: keyboardLanguage
        )
    }

    private func apply(_ state: BridgeState) {
        if state.serverID == latestState.serverID,
           state.revision < latestState.revision { return }
        latestState = state

        if state.serverID != nil,
           state.preferredKeyboardLanguage != keyboardLanguage {
            setKeyboardLanguage(state.preferredKeyboardLanguage, notifyApp: false)
        }
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
        latestState = .unavailable("服务休眠，点麦克风可自动唤醒")
        refreshUI()
    }

    private func refreshUI() {
        let icon: String
        let color: UIColor

        guard hasFullAccess else {
            statusLabel.text = "需要允许完全访问"
            icon = "lock.fill"
            color = .systemGray
            applyMicStyle(icon: icon, color: color)
            return
        }

        if latestState.status == .completed,
           let requestID = latestState.requestID,
           latestState.isFreshResponse(for: requestID),
           latestState.transcribedText != nil {
            statusLabel.text = "识别完成，点此插入"
            applyMicStyle(icon: "arrow.down.doc.fill", color: .systemGreen)
            return
        }

        guard latestState.serviceReady else {
            statusLabel.text = "服务休眠"
            applyMicStyle(icon: "mic.fill", color: .systemGray)
            return
        }

        switch latestState.status {
        case .idle:
            statusLabel.text = keyboardLanguage == .chinese ? "中文 · 就绪" : "English · Ready"
            applyMicStyle(icon: "mic.fill", color: .systemBlue)
        case .starting:
            statusLabel.text = "正在连接…"
            applyMicStyle(icon: "ellipsis", color: .systemGray)
        case .recording:
            statusLabel.text = "录音中，再点结束"
            applyMicStyle(icon: "stop.fill", color: .systemRed)
        case .transcribing:
            statusLabel.text = "正在识别…"
            applyMicStyle(icon: "ellipsis", color: .systemGray)
        case .completed:
            statusLabel.text = "结果已过期"
            applyMicStyle(icon: "mic.fill", color: .systemBlue)
        case .error:
            statusLabel.text = latestState.lastError ?? "识别失败"
            applyMicStyle(icon: "arrow.clockwise", color: .systemOrange)
        }
    }

    private func applyMicStyle(icon: String, color: UIColor) {
        micButton.setImage(UIImage(systemName: icon), for: .normal)
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

        commitPendingCompositionIfNeeded()
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
            preferredKeyboardLanguage: keyboardLanguage
        )
        refreshUI()
        sendCommand(.acknowledgeResult, requestID: requestID)
    }

    private var selectedMode: TranscriptionMode {
        guard let rawValue = UserDefaults.standard.string(forKey: Defaults.transcriptionMode),
              let mode = TranscriptionMode(rawValue: rawValue) else { return .smart }
        return mode
    }

    private var storedKeyboardLanguage: KeyboardLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: Defaults.keyboardLanguage),
              let language = KeyboardLanguage(rawValue: rawValue) else { return .chinese }
        return language
    }

    private func launchVoiceKingAndResumeRecording() {
        guard !pendingAutoRecordingAfterLaunch else { return }
        pendingAutoRecordingAfterLaunch = true
        statusLabel.text = "正在启动 VoiceKing…"
        applyMicStyle(icon: "ellipsis", color: .systemGray)

        guard let url = URL(
            string: "voiceking://start-recording?mode=\(selectedMode.rawValue)&language=\(keyboardLanguage.rawValue)"
        ) else {
            pendingAutoRecordingAfterLaunch = false
            return
        }

        extensionContext?.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if !opened {
                    self.pendingAutoRecordingAfterLaunch = false
                    self.statusLabel.text = "请先打开一次 VoiceKing"
                    self.refreshUI()
                }
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
