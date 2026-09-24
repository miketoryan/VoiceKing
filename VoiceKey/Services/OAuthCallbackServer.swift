import Foundation
import Network

final class OAuthCallbackServer {
    private let port: NWEndpoint.Port = 1455
    private let redirectBase = "voiceking://auth/callback"

    func start() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [redirectBase] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first else {
                    connection.cancel()
                    return
                }

                let requestParts = firstLine.split(separator: " ")
                guard requestParts.count >= 2,
                      requestParts[0] == "GET",
                      let components = URLComponents(string: String(requestParts[1])),
                      components.path == "/auth/callback" else {
                    connection.cancel()
                    return
                }

                let query = components.query ?? ""
                let destination = query.isEmpty ? redirectBase : "\(redirectBase)?\(query)"
                let response = "HTTP/1.1 302 Found\r\nLocation: \(destination)\r\nConnection: close\r\n\r\n"

                connection.send(
                    content: response.data(using: .utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }
}
