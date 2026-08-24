import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Posts batches to an endpoint the user runs.
///
/// Every request carries the batch identifier, so a destination that receives
/// the same batch twice — which happens whenever a response is lost after the
/// server already committed — can recognise and discard the repeat. That, plus
/// stable per-record identifiers, is what lets a retry be safe.
public struct RESTDeliveryChannel: DeliveryChannel {
    private let sessions: SessionPool
    private let credentials: DestinationCredentials
    private let deviceName: String

    public init(
        session: URLSession? = nil,
        credentials: DestinationCredentials = DestinationCredentials(),
        deviceName: String = RESTDeliveryChannel.defaultDeviceName()
    ) {
        self.sessions = SessionPool(fixed: session)
        self.credentials = credentials
        self.deviceName = deviceName
    }

    /// Keeps one `URLSession` per timeout the user has chosen.
    ///
    /// Setting `URLRequest.timeoutInterval` alone is not enough. A session
    /// carries its own `timeoutIntervalForRequest`, `URLSession.shared` sets it
    /// to sixty seconds, and a request asking for half an hour inside that
    /// session does not get half an hour. The whole point of the setting is the
    /// user with a slow home server, so it has to be the session that is
    /// configured, not only the request.
    ///
    /// There are six choices, so the pool is at most six sessions and they live
    /// as long as the app does — which is what a `URLSession` is for. A session
    /// per request would open a new connection pool every time and lose keep
    /// alive on exactly the slow servers this exists to help.
    private actor SessionPool {
        private let fixed: URLSession?
        private var sessions: [Int: URLSession] = [:]

        init(fixed: URLSession?) {
            self.fixed = fixed
        }

        func session(timeout: TimeInterval) -> URLSession {
            // An injected session is used exactly as given. A test that stubs
            // the network must not have its stub swapped out from under it.
            if let fixed {
                return fixed
            }
            let key = Int(timeout.rounded())
            if let existing = sessions[key] {
                return existing
            }
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            // How long the transfer as a whole may take. Left generous: the
            // per-request timeout is the one the user chose, and clamping the
            // resource timeout to the same number would abandon a large upload
            // that is making steady progress.
            configuration.timeoutIntervalForResource = max(timeout * 4, 600)
            let session = URLSession(configuration: configuration)
            sessions[key] = session
            return session
        }
    }

    /// What this device calls itself, so a receiver can say which phone is
    /// connected rather than that something unnamed is.
    public static func defaultDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "A device"
        #endif
    }

    public func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        guard let url = destination.endpointURL else {
            throw DeliveryError.notConfigured
        }

        // A batch too large for the destination's own limit is sent as several
        // smaller requests instead of one the server will refuse. Every record
        // lands in exactly one part, and the parts go in order.
        let parts = destination.maxRequestBytes.map { limit in
            PayloadDivision.divide(
                batch.payload,
                format: batch.format,
                maxBytes: limit,
                influxPrecision: destination.influxOptions.precision,
                dateStyle: destination.pointDateStyle
            )
        } ?? [batch.payload]

        let secret = try authorization(for: destination)
        let session = await sessions.session(timeout: destination.requestTimeout)
        var statusCode = 0

        for (index, part) in parts.enumerated() {
            let request = self.request(
                url: url,
                part: part,
                index: index,
                of: parts.count,
                batch: batch,
                destination: destination,
                secret: secret
            )
            do {
                statusCode = try await send(request, on: session)
            } catch let failure as DeliveryError {
                guard parts.count > 1 else {
                    throw failure
                }
                // Stopping here rather than trying the rest is deliberate.
                // Sending part five after part three was refused would leave a
                // hole in the middle that the receiving end has no way to
                // notice, and a gap nobody can see is worse than a failure
                // everybody can.
                throw DeliveryError.incompleteBatch(
                    accepted: index,
                    total: parts.count,
                    detail: failure.errorDescription ?? "",
                    isTransient: failure.isTransient
                )
            }
        }

        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered,
            detail: parts.count > 1
                ? "HTTP \(statusCode), sent in \(parts.count) requests"
                : "HTTP \(statusCode)"
        )
    }

    /// One request carrying one part.
    private func request(
        url: URL,
        part: Data,
        index: Int,
        of total: Int,
        batch: DeliveryBatch,
        destination: Destination,
        secret: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The destination's own timeout. `URLSession` applies its default of
        // sixty seconds otherwise, which turns a slow-but-working home server
        // into a transport failure the user reads as "my server is broken".
        request.timeoutInterval = destination.requestTimeout
        // Names this phone so a receiver can show which device is connected.
        request.setValue(deviceName, forHTTPHeaderField: "X-Hozz-Device")
        request.setValue(batch.format.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            batch.id.uuidString.lowercased(),
            forHTTPHeaderField: "Hozz-Batch-Id"
        )
        request.setValue(String(batch.sequence), forHTTPHeaderField: "Hozz-Batch-Sequence")

        // The record count is this part's, not the whole batch's, because it
        // describes the body it arrives with. A receiver checking that it read
        // as many records as it was promised must not be told about records
        // that are in a different request.
        let records = PayloadDivision.decompose(
            part,
            format: batch.format,
            influxPrecision: destination.influxOptions.precision,
            dateStyle: destination.pointDateStyle
        )?.count
        request.setValue(
            String(records ?? batch.recordCount),
            forHTTPHeaderField: "Hozz-Record-Count"
        )

        if total > 1 {
            request.setValue(String(index + 1), forHTTPHeaderField: "Hozz-Part")
            request.setValue(String(total), forHTTPHeaderField: "Hozz-Part-Count")
        }

        // An idempotency key by its conventional name, so receivers that
        // already understand the pattern need no special handling.
        //
        // Derived from **this part's** bytes rather than the batch's. Giving
        // every part the batch's key would make a correct receiver treat parts
        // two onwards as repeats of part one and discard them — the batch would
        // arrive one fifth complete and look perfect from both ends.
        request.setValue(
            (total > 1 ? DeliveryBatch.identifier(for: part) : batch.id)
                .uuidString.lowercased(),
            forHTTPHeaderField: "Idempotency-Key"
        )

        for (name, value) in destination.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let secret {
            request.setValue(secret, forHTTPHeaderField: destination.authorizationHeader)
        }
        request.httpBody = part
        return request
    }

    /// The stored secret, or nil when there is none.
    ///
    /// A Keychain read can fail transiently, most often because the device has
    /// not been unlocked since boot. Sending the batch unauthenticated in that
    /// case would turn a wait into a 401 the user has to diagnose, so it is
    /// reported as transient instead. Read once per delivery rather than once
    /// per part, so a split batch cannot start authenticated and finish
    /// otherwise.
    private func authorization(for destination: Destination) throws -> String? {
        do {
            guard
                let secret = try credentials.secret(for: destination.credentialKey),
                !secret.isEmpty
            else {
                return nil
            }
            return secret
        } catch {
            throw DeliveryError.transport(
                "Hozz could not read this destination's saved credential yet."
            )
        }
    }

    /// Sends one request and returns its status code, or throws.
    private func send(_ request: URLRequest, on session: URLSession) async throws -> Int {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw DeliveryError.cancelled
        } catch {
            throw DeliveryError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DeliveryError.transport("The destination sent an unreadable response.")
        }
        guard (200...299).contains(http.statusCode) else {
            // The body is deliberately discarded. A server that rejects a batch
            // frequently echoes the offending record back, and a response body
            // stored in the database or written to a log would put Health
            // sample values somewhere they must never appear. The status code
            // is enough to act on.
            _ = data
            throw DeliveryError.rejected(statusCode: http.statusCode, body: nil)
        }
        return http.statusCode
    }
}
