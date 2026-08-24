import Foundation
@testable import HozzDeliver
import HozzStore
import XCTest

/// Sending one batch as several requests.
///
/// Two properties matter and everything here is about one or the other. Every
/// reading has to arrive exactly once across the parts, and a batch that stopped
/// partway must never be recorded as delivered — a half-arrived batch reported
/// as a success is precisely the failure this codebase exists to prevent.
final class BatchRequestTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    /// Six hundred records, each about a hundred and thirty bytes, written out
    /// here rather than produced by anything under test.
    ///
    /// The sizes are deliberately above `RequestSize.minimum`: a limit below
    /// that is refused as meaningless, and a test that quietly fell under it
    /// would exercise no splitting at all while appearing to pass.
    private func manyRecords(_ count: Int = 600) -> Data {
        var payload = Data()
        for index in 0..<count {
            let line = "{\"id\":\"r\(index)\",\"kind\":\"quantity\","
                + "\"startDate\":\"2026-08-22T09:00:00.000Z\","
                + "\"type\":\"HKQuantityTypeIdentifierStepCount\","
                + "\"value\":\(index)}"
            payload.append(Data(line.utf8))
            payload.append(0x0A)
        }
        return payload
    }

    private func identifiers(in payload: Data) -> [String] {
        payload
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { slice -> String? in
                guard
                    let object = try? JSONSerialization
                        .jsonObject(with: Data(slice)) as? [String: Any]
                else {
                    return nil
                }
                return object["id"] as? String
            }
    }

    private func destination(
        maxBytes: Int?,
        name: String = "Home server"
    ) -> Destination {
        var options: [String: String] = [:]
        if let maxBytes {
            options[Destination.maxRequestBytesKey] = String(maxBytes)
        }
        return Destination(
            name: name,
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            options: options
        )
    }

    private func batch(_ payload: Data) -> DeliveryBatch {
        DeliveryBatch(
            id: DeliveryBatch.identifier(for: payload),
            sequence: 7,
            createdAt: .now,
            recordCount: payload
                .split(separator: 0x0A, omittingEmptySubsequences: true)
                .count,
            payload: payload,
            format: .ndjson
        )
    }

    private func channel() -> RESTDeliveryChannel {
        RESTDeliveryChannel(
            session: StubProtocol.session(),
            credentials: DestinationCredentials(service: "hozz.tests.batching"),
            deviceName: "Test"
        )
    }

    // MARK: - Splitting by size

    func testEveryRecordArrivesExactlyOnceAcrossTheParts() async throws {
        StubProtocol.reset()
        let payload = manyRecords()
        let expected = identifiers(in: payload)
        XCTAssertEqual(expected.count, 600, "The fixture itself has to be right.")

        _ = try await channel().deliver(
            batch(payload),
            to: destination(maxBytes: 20 * 1_024)
        )

        let seen = StubProtocol.seen()
        XCTAssertGreaterThan(seen.bodies.count, 1, "It should actually have split.")
        XCTAssertEqual(
            seen.bodies.flatMap(identifiers(in:)),
            expected,
            "Every reading, in order, once."
        )
    }

    func testNoPartExceedsTheLimitItWasGiven() async throws {
        StubProtocol.reset()

        _ = try await channel().deliver(
            batch(manyRecords()),
            to: destination(maxBytes: 20 * 1_024)
        )

        for body in StubProtocol.seen().bodies {
            XCTAssertLessThanOrEqual(
                body.count,
                20 * 1_024,
                "A part over the limit is a part the server refuses."
            )
        }
    }

    func testABatchInsideTheLimitIsStillOneRequest() async throws {
        StubProtocol.reset()
        let payload = manyRecords(3)

        _ = try await channel().deliver(
            batch(payload),
            to: destination(maxBytes: 1_024 * 1_024)
        )

        let seen = StubProtocol.seen()
        XCTAssertEqual(seen.bodies.count, 1)
        XCTAssertEqual(seen.bodies[0], payload, "Byte for byte, unsplit.")
    }

    func testADestinationWithNoLimitSendsOneRequestHoweverLarge() async throws {
        StubProtocol.reset()
        let payload = manyRecords(200)

        _ = try await channel().deliver(batch(payload), to: destination(maxBytes: nil))

        let seen = StubProtocol.seen()
        XCTAssertEqual(seen.bodies.count, 1, "Splitting is off unless asked for.")
        XCTAssertEqual(seen.bodies[0], payload)
    }

    /// One record bigger than the limit cannot be made smaller without throwing
    /// away part of a reading, so it goes on its own and the server decides.
    func testAnOversizeSingleRecordIsSentRatherThanDropped() async throws {
        StubProtocol.reset()
        let big = "{\"id\":\"huge\",\"kind\":\"quantity\","
            + "\"startDate\":\"2026-08-22T09:00:00.000Z\",\"note\":\""
            + String(repeating: "x", count: 30_000) + "\"}"
        let payload = Data((big + "\n").utf8)

        _ = try await channel().deliver(batch(payload), to: destination(maxBytes: 20 * 1_024))

        let seen = StubProtocol.seen()
        XCTAssertEqual(seen.bodies.count, 1)
        XCTAssertEqual(identifiers(in: seen.bodies[0]), ["huge"])
    }

    // MARK: - Headers

    /// Giving every part the batch's key would make a correct receiver treat
    /// parts two onwards as repeats of part one and discard them. The batch
    /// would arrive a fifth complete and look perfect from both ends.
    func testEachPartCarriesItsOwnIdempotencyKey() async throws {
        StubProtocol.reset()

        _ = try await channel().deliver(
            batch(manyRecords()),
            to: destination(maxBytes: 20 * 1_024)
        )

        let seen = StubProtocol.seen()
        let keys = seen.requests.compactMap {
            $0.value(forHTTPHeaderField: "Idempotency-Key")
        }
        XCTAssertEqual(keys.count, seen.bodies.count)
        XCTAssertEqual(
            Set(keys).count,
            keys.count,
            "Two parts sharing a key is one of them being thrown away."
        )

        // And each key is the hash of the body it travelled with, computed here
        // from the body the stub actually received.
        for (request, body) in zip(seen.requests, seen.bodies) {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Idempotency-Key"),
                DeliveryBatch.identifier(for: body).uuidString.lowercased()
            )
        }
    }

    func testEveryPartSharesTheBatchIdentifierSoTheyCanBeGrouped() async throws {
        StubProtocol.reset()
        let payload = manyRecords()
        let sent = batch(payload)

        _ = try await channel().deliver(sent, to: destination(maxBytes: 20 * 1_024))

        let ids = Set(
            StubProtocol.seen().requests.compactMap {
                $0.value(forHTTPHeaderField: "Hozz-Batch-Id")
            }
        )
        XCTAssertEqual(ids, [sent.id.uuidString.lowercased()])
    }

    func testThePartNumbersRunFromOneToTheCount() async throws {
        StubProtocol.reset()

        _ = try await channel().deliver(
            batch(manyRecords()),
            to: destination(maxBytes: 20 * 1_024)
        )

        let seen = StubProtocol.seen()
        let parts = seen.requests.compactMap {
            $0.value(forHTTPHeaderField: "Hozz-Part").flatMap(Int.init)
        }
        let counts = Set(
            seen.requests.compactMap { $0.value(forHTTPHeaderField: "Hozz-Part-Count") }
        )
        XCTAssertEqual(parts, Array(1...seen.bodies.count))
        XCTAssertEqual(counts, [String(seen.bodies.count)])
    }

    /// A receiver checking that it read as many records as it was promised must
    /// not be told about records that are in a different request.
    func testTheRecordCountOnEachPartDescribesThatPart() async throws {
        StubProtocol.reset()

        _ = try await channel().deliver(
            batch(manyRecords()),
            to: destination(maxBytes: 20 * 1_024)
        )

        let seen = StubProtocol.seen()
        var total = 0
        for (request, body) in zip(seen.requests, seen.bodies) {
            let claimed = Int(
                request.value(forHTTPHeaderField: "Hozz-Record-Count") ?? ""
            )
            XCTAssertEqual(claimed, identifiers(in: body).count)
            total += claimed ?? 0
        }
        XCTAssertEqual(total, 600, "And the parts add up to the whole.")
    }

    func testAnUnsplitBatchIsUnchangedAndCarriesNoPartHeaders() async throws {
        StubProtocol.reset()
        let payload = manyRecords(3)
        let sent = batch(payload)

        _ = try await channel().deliver(sent, to: destination(maxBytes: nil))

        let request = StubProtocol.seen().requests[0]
        XCTAssertNil(request.value(forHTTPHeaderField: "Hozz-Part"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            sent.id.uuidString.lowercased(),
            "An unsplit batch keeps behaving exactly as it did before."
        )
    }

    // MARK: - When a part fails

    /// Sending part five after part three was refused would leave a hole in the
    /// middle that the receiving end has no way to notice.
    func testAFailedPartStopsTheRestFromBeingSent() async throws {
        // Accept the first two, refuse the third, and be willing to accept
        // anything after that — so the test fails loudly if it carries on.
        StubProtocol.reset(sequence: [200, 200, 500, 200])

        do {
            _ = try await channel().deliver(
                batch(manyRecords()),
                to: destination(maxBytes: 20 * 1_024)
            )
            XCTFail("A refused part must not be reported as a delivery.")
        } catch let error as DeliveryError {
            guard case .incompleteBatch(let accepted, let total, _, _) = error else {
                return XCTFail("Wrong error: \(error)")
            }
            XCTAssertEqual(accepted, 2)
            XCTAssertGreaterThan(total, 3)
        }

        XCTAssertEqual(
            StubProtocol.seen().bodies.count,
            3,
            "Two accepted and the one that failed. Nothing after it."
        )
    }

    func testTheErrorSaysHowManyOfHowManyWereAccepted() {
        let error = DeliveryError.incompleteBatch(
            accepted: 2,
            total: 5,
            detail: "The destination refused the data (HTTP 500).",
            isTransient: true
        )
        let described = error.errorDescription ?? ""

        XCTAssertTrue(described.contains("5 requests"), described)
        XCTAssertTrue(described.contains("2 of them"), described)
        XCTAssertTrue(
            described.contains("Nothing has been counted as delivered"),
            described
        )
    }

    /// A split delivery that stopped on a 500 deserves the same patience as an
    /// unsplit one, and one that stopped on a 413 deserves the same attention.
    func testTheRetryBehaviourFollowsWhateverStoppedIt() {
        let transient = DeliveryError.incompleteBatch(
            accepted: 1,
            total: 4,
            detail: "",
            isTransient: true
        )
        let permanent = DeliveryError.incompleteBatch(
            accepted: 1,
            total: 4,
            detail: "",
            isTransient: false
        )

        XCTAssertTrue(transient.isTransient)
        XCTAssertEqual(transient.deliveryState, .retrying)
        XCTAssertFalse(permanent.isTransient)
        XCTAssertEqual(permanent.deliveryState, .needsAttention)
    }

    /// The property the whole feature turns on: a batch that stopped partway is
    /// recorded as a failure, contributes nothing to the delivered count, and
    /// leaves the destination due for another attempt.
    func testAPartialDeliveryIsNeverRecordedAsASuccess() async throws {
        StubProtocol.reset(sequence: [200, 200, 500])
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(
            store: store,
            channels: [.restAPI: channel()]
        )
        let destination = destination(maxBytes: 20 * 1_024)
        try await engine.save(destination)

        do {
            _ = try await engine.deliver(batch(manyRecords()), to: destination)
            XCTFail("A partial delivery must not succeed.")
        } catch {
            // Expected.
        }

        let state = try await engine.state(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.retrying.rawValue)
        XCTAssertEqual(
            state?.deliveredRecords,
            0,
            "None of it counts, including the parts the server did take."
        )
        XCTAssertNotNil(state?.nextAttemptAt, "It has to be tried again.")
        XCTAssertNil(state?.lastSuccessAt)

        let receipts = try await engine.receipts(for: destination.id)
        XCTAssertEqual(receipts.first?.state, DeliveryState.retrying.rawValue)
        let detail = try XCTUnwrap(receipts.first?.detail)
        XCTAssertTrue(detail.contains("accepted 2"), detail)
    }

    /// Retrying re-sends from the first part. The parts that already landed
    /// carry the same bytes and therefore the same key, so a receiver that
    /// honours it stores each reading once.
    func testARetrySendsTheSamePartsWithTheSameKeys() async throws {
        StubProtocol.reset(sequence: [200, 200, 500])
        let payload = manyRecords()
        _ = try? await channel().deliver(
            batch(payload),
            to: destination(maxBytes: 20 * 1_024)
        )
        let firstAttempt = StubProtocol.seen()

        StubProtocol.reset()
        _ = try await channel().deliver(
            batch(payload),
            to: destination(maxBytes: 20 * 1_024)
        )
        let secondAttempt = StubProtocol.seen()

        XCTAssertEqual(
            Array(secondAttempt.bodies.prefix(firstAttempt.bodies.count)),
            firstAttempt.bodies,
            "The same records must divide the same way, or the keys change."
        )
        XCTAssertEqual(
            secondAttempt.requests.prefix(2).compactMap {
                $0.value(forHTTPHeaderField: "Idempotency-Key")
            },
            firstAttempt.requests.prefix(2).compactMap {
                $0.value(forHTTPHeaderField: "Idempotency-Key")
            }
        )
        XCTAssertEqual(
            secondAttempt.bodies.flatMap(identifiers(in:)),
            identifiers(in: payload),
            "And the retry delivers all of it."
        )
    }

    // MARK: - Reading the stored value

    func testAnUnreadableOrTinyLimitMeansNoSplitting() {
        for value in ["", "none", "-1", "0", "512"] {
            XCTAssertNil(
                Destination(
                    name: "n",
                    kind: .restAPI,
                    options: [Destination.maxRequestBytesKey: value]
                ).maxRequestBytes,
                "\(value) should mean no splitting at all."
            )
        }
        XCTAssertEqual(
            Destination(
                name: "n",
                kind: .restAPI,
                options: [Destination.maxRequestBytesKey: "1048576"]
            ).maxRequestBytes,
            1_048_576
        )
    }

    func testTheSizeNamesMatchTheBytes() {
        XCTAssertEqual(RequestSize.displayName(for: 256 * 1_024), "256 KB")
        XCTAssertEqual(RequestSize.displayName(for: 1_024 * 1_024), "1 MB")
        XCTAssertEqual(RequestSize.displayName(for: 4 * 1_024 * 1_024), "4 MB")
    }
}
