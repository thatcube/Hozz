import Foundation
import HozzAcquire
import HozzCore
import HozzStore
import XCTest
@testable import HozzHealth

/// What must happen when a series sample cannot be encoded.
///
/// The failure this prevents was live on Brandon's phone for weeks. A workout
/// route delivered 541 records and then stopped: a series backend reads
/// exactly one sample per page, the encode threw before the cursor could move,
/// and every later pass read the same sample and failed the same way. The
/// electrocardiogram stream has the identical shape and had simply not met a
/// bad sample yet.
///
/// The fix carries its own risk, and it is the one these tests are really for.
/// Today the stall is the *conservative* failure — a cursor that does not
/// advance is what keeps those records safe. Advancing past a sample without
/// recording it would convert a visible stall into silent record loss, which
/// is the one thing this app forbids outright. **So the rule is not "the
/// cursor advances", it is "the cursor advances only in the same batch as a
/// record standing in for what it moved past".** A batch is committed whole or
/// not at all, so putting both in one batch is what makes it safe.
final class SeriesResilienceTests: XCTestCase {
    private static let shape = SeriesShape(
        typeIdentifier: "HKWorkoutRouteTypeIdentifier",
        headerKind: "workoutRoute",
        elementKind: "workoutRouteLocations",
        endKind: "workoutRouteEnd",
        elementsKey: "locations",
        elementsPerRecord: 500,
        recordsPerPage: 8
    )

    /// A backend whose samples are simply listed, one of which it cannot
    /// encode. Anchors are the offset as text, so a stalled cursor is visible
    /// as a number that does not change.
    private actor StubBackend: SeriesBackend {
        struct Sample {
            let id: UUID
            let isEncodable: Bool
        }

        private let samples: [Sample]
        private(set) var pagesRead = 0

        init(samples: [Sample]) {
            self.samples = samples
        }

        func nextPage(after anchor: Data?) async throws -> SeriesPage {
            pagesRead += 1
            let offset = anchor
                .flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let next = Data(String(offset + 1).utf8)

            guard offset < samples.count else {
                return SeriesPage(
                    header: nil,
                    deletions: [],
                    anchor: Data(String(offset).utf8)
                )
            }

            let sample = samples[offset]
            guard sample.isEncodable else {
                return SeriesPage(
                    header: nil,
                    deletions: [],
                    anchor: next,
                    unencodable: UnencodableSample(
                        id: sample.id,
                        reason: "invalidJSONObject"
                    )
                )
            }
            return SeriesPage(
                header: SeriesHeader(
                    id: sample.id,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    endDate: Date(timeIntervalSince1970: 1_700_000_060),
                    basePayload: try JSONSerialization.data(
                        withJSONObject: ["id": sample.id.uuidString] as [String: Any],
                        options: [.sortedKeys]
                    )
                ),
                deletions: [],
                anchor: next
            )
        }

        func facts(id: UUID) async throws -> SeriesFacts? {
            SeriesFacts(
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: Date(timeIntervalSince1970: 1_700_000_060)
            )
        }

        /// Never reached: every sample here is either unencodable or has no
        /// elements worth paging, and the point under test is the header step.
        nonisolated func elements(
            for id: UUID
        ) -> AsyncThrowingStream<[RouteLocation], any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // MARK: - The rule

    /// The deliverable. A cursor may move past a sample only in the same batch
    /// as a record standing in for it.
    ///
    /// Asserted **per batch**, not over the drain as a whole. That distinction
    /// is the whole test: a reader that advanced in one batch with nothing and
    /// wrote the stand-in in the next would satisfy "every sample produced a
    /// record eventually" while being exactly the unsafe design, because a
    /// batch is the unit that commits atomically. If the advance lands and the
    /// record does not, the sample is gone and nothing says so.
    ///
    /// The stub's anchor is the offset as text, so which samples a batch moved
    /// past is readable rather than inferred.
    func testNoSampleIsPassedWithoutARecordInTheSameBatch() async throws {
        let ids = (0..<6).map { _ in UUID() }
        let backend = StubBackend(
            samples: ids.enumerated().map {
                StubBackend.Sample(id: $1, isEncodable: $0 % 2 == 0)
            }
        )
        let reader = SeriesReader<StubBackend>(shape: Self.shape, backend: backend)

        var offset = 0
        var anchor: AnchorToken?
        var accountedFor: Set<UUID> = []

        for _ in 0..<24 {
            let batch = try await reader.changes(after: anchor, limit: 500)
            let moved = Self.offset(of: batch.proposedAnchor)

            let written = Set(
                batch.changes.compactMap { change -> UUID? in
                    if case .upsert(let object) = change { return object.id }
                    return nil
                }
            )
            // Every sample this batch moved the cursor past has to have a
            // record in *this* batch. A sample already accounted for by an
            // earlier batch is fine — that is the paged case, where the header
            // lands first and the elements follow.
            for index in offset..<max(offset, moved) {
                guard index < ids.count else { continue }
                XCTAssertTrue(
                    written.contains(ids[index]) || accountedFor.contains(ids[index]),
                    "the cursor moved past sample \(index) in a batch that "
                        + "carried no record for it"
                )
            }
            accountedFor.formUnion(written)

            if moved == offset, batch.changes.isEmpty {
                break
            }
            offset = moved
            anchor = batch.proposedAnchor
        }

        for (index, id) in ids.enumerated() {
            XCTAssertTrue(
                accountedFor.contains(id),
                "sample \(index) was never recorded at all"
            )
        }
        XCTAssertEqual(offset, ids.count, "the drain reached the end")
    }

    /// Reads the stub's anchor back as the offset it encodes.
    private static func offset(of token: AnchorToken) -> Int {
        let anchor = try? SeriesAnchor.decode(token)
        guard let raw = anchor?.healthKitAnchor else { return 0 }
        return Int(String(decoding: raw, as: UTF8.self)) ?? 0
    }

    /// And the stand-in has to say what it is, rather than looking like data.
    func testTheStandInIsRecordedAsAnEncodingFailure() async throws {
        let bad = UUID()
        let backend = StubBackend(
            samples: [StubBackend.Sample(id: bad, isEncodable: false)]
        )
        let reader = SeriesReader<StubBackend>(shape: Self.shape, backend: backend)

        let batch = try await reader.changes(after: nil, limit: 500)
        XCTAssertEqual(batch.changes.count, 1)

        guard case .upsert(let object) = try XCTUnwrap(batch.changes.first) else {
            return XCTFail("a stand-in has to be a record, not a deletion")
        }
        let failureID = HealthSampleEncoder.encodingFailureID(
            sourceRecordID: bad,
            typeIdentifier: "HKWorkoutRouteTypeIdentifier"
        )
        XCTAssertEqual(object.id, bad)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: object.canonicalPayload)
                as? [String: Any]
        )
        XCTAssertEqual(payload["kind"] as? String, "sampleEncodingError")
        XCTAssertEqual(
            payload["id"] as? String,
            failureID.uuidString.lowercased()
        )
        XCTAssertEqual(
            payload["type"] as? String,
            "HKWorkoutRouteTypeIdentifier"
        )
        XCTAssertTrue(
            (payload["message"] as? String)?.contains("invalidJSONObject") == true,
            "the reason travels, so the next investigation needs no phone: "
                + String(describing: payload["message"])
        )
    }

    /// The stall itself: the state before this change, asserted so a
    /// regression is nameable rather than merely slower.
    func testOneUnencodableSampleNoLongerStopsEverythingBehindIt() async throws {
        let bad = UUID()
        let good = UUID()
        let backend = StubBackend(
            samples: [
                StubBackend.Sample(id: bad, isEncodable: false),
                StubBackend.Sample(id: good, isEncodable: true)
            ]
        )
        let reader = SeriesReader<StubBackend>(shape: Self.shape, backend: backend)

        let first = try await reader.changes(after: nil, limit: 500)
        let second = try await reader.changes(
            after: first.proposedAnchor,
            limit: 500
        )

        XCTAssertNotEqual(
            first.proposedAnchor,
            second.proposedAnchor,
            "the cursor has to move, or the sample behind is unreachable"
        )
        let reached = second.changes.contains {
            if case .upsert(let object) = $0 { return object.id == good }
            return false
        }
        XCTAssertTrue(
            reached,
            "the readable sample behind the bad one never arrived"
        )
    }

    /// A page that carries neither a header nor a failure must not move the
    /// cursor *and* write nothing — that is the shape of a silent skip, and it
    /// is worth pinning that the empty page keeps its own meaning.
    func testAnEmptyPageStillMeansTheStreamIsCaughtUp() async throws {
        let backend = StubBackend(samples: [])
        let reader = SeriesReader<StubBackend>(shape: Self.shape, backend: backend)

        let batch = try await reader.changes(after: nil, limit: 500)
        XCTAssertTrue(batch.changes.isEmpty)
    }
}
