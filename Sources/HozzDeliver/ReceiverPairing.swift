import Foundation
import HozzCore

public enum PairingError: Error, LocalizedError, Sendable {
    case alreadyPaired(String)
    case unreachable
    case refused(Int)
    case malformedReply

    public var errorDescription: String? {
        switch self {
        case .alreadyPaired(let detail):
            detail
        case .unreachable:
            "That computer did not answer. Is Hozz still open on it?"
        case .refused(let status):
            "That computer refused the request (\(status))."
        case .malformedReply:
            "That computer answered in a way Hozz did not understand."
        }
    }
}

public struct PairingResult: Hashable, Sendable {
    public let token: String
    /// What the computer calls itself, so the destination is named sensibly.
    public let name: String

    public init(token: String, name: String) {
        self.token = token
        self.name = name
    }
}

/// Asks a discovered receiver for permission to send to it.
///
/// This is what makes connecting a computer a single tap. Without it the user
/// has to copy a token between two devices by hand, which is the step people
/// abandon — and the token is long and random precisely so it is unpleasant to
/// retype.
public struct ReceiverPairing: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func pair(
        with endpoint: String,
        deviceName: String
    ) async throws -> PairingResult {
        guard
            let base = URL(string: endpoint),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            throw PairingError.unreachable
        }
        components.path = "/pair"
        guard let url = components.url else {
            throw PairingError.unreachable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["device": deviceName]
        )
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard status == 200 else {
            if status == 403, let detail = body?["detail"] as? String {
                throw PairingError.alreadyPaired(detail)
            }
            throw PairingError.refused(status)
        }
        guard let token = body?["token"] as? String, !token.isEmpty else {
            throw PairingError.malformedReply
        }
        return PairingResult(
            token: token,
            name: body?["name"] as? String ?? "Mac"
        )
    }
}
