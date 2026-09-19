import Foundation

enum LocalBridge {
    static let port = 14_557
    static let protocolVersion = "6"
    static let keyboardHeartbeatInterval: Duration = .seconds(2)
    static let keyboardExitGracePeriod: TimeInterval = 10
    static let resultValidity: TimeInterval = 300

    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
}

enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case smart
    case verbatim

    var displayName: String {
        switch self {
        case .smart: "智能整理"
        case .verbatim: "原文模式"
        }
    }
}

enum KeyboardLanguage: String, Codable, CaseIterable, Sendable {
    case chinese
    case english

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }
}

enum BridgeAction: String, Codable, Sendable {
    case state
    case heartbeat
    case startRecording
    case stopRecording
    case acknowledgeResult
    case setKeyboardLanguage
}

struct BridgeRequest: Codable, Sendable {
    let action: BridgeAction
    let requestID: String?
    let mode: TranscriptionMode?
    let language: KeyboardLanguage?

    init(
        action: BridgeAction,
        requestID: String? = nil,
        mode: TranscriptionMode? = nil,
        language: KeyboardLanguage? = nil
    ) {
        self.action = action
        self.requestID = requestID
        self.mode = mode
        self.language = language
    }
}

enum BridgeStatus: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case transcribing
    case completed
    case error
}

struct BridgeState: Codable, Sendable {
    let serverID: String?
    let revision: UInt64
    let serviceReady: Bool
    let microphoneReady: Bool
    let status: BridgeStatus
    let requestID: String?
    let transcribedText: String?
    let resultCreatedAt: Date?
    let lastError: String?
    let preferredKeyboardLanguage: KeyboardLanguage

    init(
        serverID: String?,
        revision: UInt64,
        serviceReady: Bool,
        microphoneReady: Bool = false,
        status: BridgeStatus,
        requestID: String?,
        transcribedText: String?,
        resultCreatedAt: Date?,
        lastError: String?,
        preferredKeyboardLanguage: KeyboardLanguage = .chinese
    ) {
        self.serverID = serverID
        self.revision = revision
        self.serviceReady = serviceReady
        self.microphoneReady = microphoneReady
        self.status = status
        self.requestID = requestID
        self.transcribedText = transcribedText
        self.resultCreatedAt = resultCreatedAt
        self.lastError = lastError
        self.preferredKeyboardLanguage = preferredKeyboardLanguage
    }

    static func unavailable(_ message: String? = nil) -> BridgeState {
        BridgeState(
            serverID: nil,
            revision: 0,
            serviceReady: false,
            microphoneReady: false,
            status: .idle,
            requestID: nil,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: message,
            preferredKeyboardLanguage: .chinese
        )
    }

    func isFreshResponse(for id: String) -> Bool {
        guard requestID == id, let resultCreatedAt else { return false }
        return Date().timeIntervalSince(resultCreatedAt) <= LocalBridge.resultValidity
    }
}

struct LocalBridgeClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchState() async throws -> BridgeState {
        var request = URLRequest(url: LocalBridge.stateURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-VoiceKing-Protocol")
        return try await perform(request)
    }

    func send(
        _ action: BridgeAction,
        requestID: String? = nil,
        mode: TranscriptionMode? = nil,
        language: KeyboardLanguage? = nil
    ) async throws -> BridgeState {
        var request = URLRequest(url: LocalBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-VoiceKing-Protocol")
        request.httpBody = try JSONEncoder().encode(
            BridgeRequest(
                action: action,
                requestID: requestID,
                mode: mode,
                language: language
            )
        )
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> BridgeState {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw BridgeClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(BridgeState.self, from: data)
    }

    enum BridgeClientError: LocalizedError {
        case invalidResponse
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "VoiceKing returned an invalid response."
            case .http(let status):
                "VoiceKing communication failed (HTTP \(status))."
            }
        }
    }
}
