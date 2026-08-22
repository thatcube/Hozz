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
    private let session: URLSession
    private let credentials: DestinationCredentials
    private let deviceName: String

    public init(
        session: URLSession = .shared,
        credentials: DestinationCredentials = DestinationCredentials(),
        deviceName: String = RESTDeliveryChannel.defaultDeviceName()
    ) {
        self.session = session
        self.credentials = credentials
        self.deviceName = deviceName
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Names this phone so a receiver can show which device is connected.
        request.setValue(deviceName, forHTTPHeaderField: "X-Hozz-Device")
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
        // A Keychain read can fail transiently, most often because the device
        // has not been unlocked since boot. Sending the batch unauthenticated
        // in that case would turn a wait into a 401 the user has to diagnose,
        // so it is reported as transient instead.
        do {
            if let secret = try credentials.secret(for: destination.credentialKey),
               !secret.isEmpty {
                request.setValue(
                    secret,
                    forHTTPHeaderField: destination.authorizationHeader
                )
            }
        } catch {
            throw DeliveryError.transport(
                "Hozz could not read this destination's saved credential yet."
            )
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
            // The body is deliberately discarded. A server that rejects a batch
            // frequently echoes the offending record back, and a response body
            // stored in the database or written to a log would put Health
            // sample values somewhere they must never appear. The status code
            // is enough to act on.
            _ = data
            throw DeliveryError.rejected(statusCode: http.statusCode, body: nil)
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
