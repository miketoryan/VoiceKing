import Foundation

enum LocalBridge {
    static let port = 14_556
    static let protocolVersion = "1"
    static let keyboardHeartbeatInterval: Duration = .seconds(2)
    static let keyboardExitGracePeriod: TimeInterval = 10
    static let resultValidity: TimeInterval = 300

    static let commandURL = URL(string: "http://127.0.0.1:\(port)/command")!
    static let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
}

enum BridgeAction: String, Codable, Sendable {
    case state
    case heartbeat
    case startRecording
    case stopRecording
    case acknowledgeResult
}

struct BridgeRequest: Codable, Sendable {
    let action: BridgeAction
    let requestID: String?

    init(action: BridgeAction, requestID: String? = nil) {
        self.action = action
        self.requestID = requestID
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
    let status: BridgeStatus
    let requestID: String?
    let transcribedText: String?
    let resultCreatedAt: Date?
    let lastError: String?

    static func unavailable(_ message: String? = nil) -> BridgeState {
        BridgeState(
            serverID: nil,
            revision: 0,
            serviceReady: false,
            status: .idle,
            requestID: nil,
            transcribedText: nil,
            resultCreatedAt: nil,
            lastError: message
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
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-VoiceKey-Protocol")
        return try await perform(request)
    }

    func send(_ action: BridgeAction, requestID: String? = nil) async throws -> BridgeState {
        var request = URLRequest(url: LocalBridge.commandURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(LocalBridge.protocolVersion, forHTTPHeaderField: "X-VoiceKey-Protocol")
        request.httpBody = try JSONEncoder().encode(BridgeRequest(action: action, requestID: requestID))
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
                "VoiceKey returned an invalid response."
            case .http(let status):
                "VoiceKey communication failed (HTTP \(status))."
            }
        }
    }
}
