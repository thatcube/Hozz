import Foundation

/// Posts batches to an endpoint the user runs.
///
/// Every request carries the batch identifier, so a destination that receives
/// the same batch twice — which happens whenever a response is lost after the
/// server already committed — can recognise and discard the repeat. That, plus
/// stable per-record identifiers, is what lets a retry be safe.
public struct RESTDeliveryChannel: DeliveryChannel {
    private let session: URLSession
    private let credentials: DestinationCredentials

    public init(
        session: URLSession = .shared,
        credentials: DestinationCredentials = DestinationCredentials()
    ) {
        self.session = session
        self.credentials = credentials
    }

    public func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        guard let url = destination.endpointURL else {
            throw DeliveryError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(batch.format.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            batch.id.uuidString.lowercased(),
            forHTTPHeaderField: "Hozz-Batch-Id"
        )
        request.setValue(String(batch.sequence), forHTTPHeaderField: "Hozz-Batch-Sequence")
        request.setValue(String(batch.recordCount), forHTTPHeaderField: "Hozz-Record-Count")
        // An idempotency key by its conventional name, so receivers that
        // already understand the pattern need no special handling.
        request.setValue(
            batch.id.uuidString.lowercased(),
            forHTTPHeaderField: "Idempotency-Key"
        )

        for (name, value) in destination.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let secret = try? credentials.secret(for: destination.credentialKey),
           !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: destination.authorizationHeader)
        }
        request.httpBody = batch.payload

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
            // Only a short prefix is kept: a response body can quote the data
            // that was sent, and diagnostics must never contain sample values.
            let snippet = String(data: data.prefix(200), encoding: .utf8)
            throw DeliveryError.rejected(statusCode: http.statusCode, body: snippet)
        }

        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered,
            detail: "HTTP \(http.statusCode)"
        )
    }
}
