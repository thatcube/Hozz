import Foundation
import HozzCore

/// Finds which of a computer's addresses actually works from here.
///
/// There is no single address that is right everywhere. A home address works
/// on the same Wi-Fi and nowhere else; a Tailscale address works from anywhere
/// on the tailnet but only while it is up. Rather than guess, or make the user
/// understand the difference, each candidate is tried and the first that
/// answers is used.
///
/// This is also what stops a working setup dying quietly: routers reassign
/// addresses, laptops move between networks, VPNs come and go. Re-probing turns
/// all of that from "it just stopped syncing and I don't know why" into a
/// moment's delay.
public struct ReceiverProbe: Sendable {
    /// The identity a genuine receiver reports.
    static let expectedService = "hozz-receiver"

    private let session: URLSession

    public init(timeout: TimeInterval = 3) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Never let a probe answer from a cache; the whole question is whether
        // this address is reachable *now*.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// The first address that answers as a Hozz receiver, or `nil`.
    ///
    /// Candidates are tried in order rather than all at once, because the order
    /// encodes a real preference: the local address is faster and keeps traffic
    /// on the local network, and should win whenever it works.
    public func firstReachable(among candidates: [String]) async -> String? {
        for candidate in candidates {
            if await isReceiver(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Why a probe failed, in words a person can act on.
    ///
    /// Swallowing these made every failure identical — "did not answer" —
    /// whether the computer was off, the address stale, or the request refused
    /// by the operating system before it ever left the phone.
    public func failureReason(for endpoint: String) async -> String? {
        guard let url = URL(string: endpoint) else {
            return "\(endpoint): not a valid address"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return "\(endpoint): answered \(status)"
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard body?["service"] as? String == Self.expectedService else {
                return "\(endpoint): something else is listening there"
            }
            return nil
        } catch {
            return "\(endpoint): \((error as NSError).localizedDescription)"
        }
    }

    /// Whether a Hozz receiver — and not merely *something* — is at this
    /// address.
    ///
    /// The identity check matters. Private address ranges are reused across
    /// networks, so an address that worked at home can easily belong to an
    /// unrelated machine elsewhere. Accepting any HTTP response would mean
    /// eventually posting someone's Health data to a stranger's server.
    public func isReceiver(_ endpoint: String) async -> Bool {
        guard let url = URL(string: endpoint) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return false
        }
        return body["service"] as? String == Self.expectedService
    }
}
