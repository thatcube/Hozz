import Foundation
import HozzCore

/// What a series stream needs from Health, kept behind a protocol so the part
/// that could lose or duplicate elements can be tested without a device that
/// has any rides or recordings on it.
public protocol SeriesBackend<Element>: Sendable {
    associatedtype Element: SeriesElement

    /// Reads exactly one sample, so a sample is never in memory beside another
    /// one's elements.
    func nextPage(after anchor: Data?) async throws -> SeriesPage

    /// The sample's start and end, used when re-opening it after a relaunch.
    /// `nil` means it is no longer in Health.
    func facts(id: UUID) async throws -> SeriesFacts?

    /// The sample's elements, in the batches Health chooses to deliver them.
    func elements(for id: UUID) -> AsyncThrowingStream<[Element], any Error>
}

/// Drains a series type, streaming each sample's elements rather than
/// collecting them.
///
/// A workout route or an electrocardiogram is one HealthKit sample whose real
/// content is somewhere else: the elements arrive in batches and a long ride
/// holds hundreds of thousands of them. Handing a sample over whole would put
/// the entire recording in memory in a process iOS is willing to kill for
/// exactly that, so a sample is drained across several pages and the cursor
/// records how far into it Hozz has got.
///
/// The stream stays open between pages, which keeps the ordinary path to a
/// single read of each element. A relaunch has no stream to continue, so it
/// re-opens the sample and skips what is already durable — paying a re-read
/// once, after an interruption, rather than on every page.
public actor SeriesReader<Backend: SeriesBackend> {
    /// Holds the live iterator by reference so it can be advanced without the
    /// actor's stored state being mutated across an `await`.
    ///
    /// `@unchecked Sendable` is the honest label rather than a shortcut: the
    /// storage behind an `AsyncThrowingStream` is already thread-safe, and this
    /// box never leaves the actor, so the only rule it relies on is the one
    /// that stream already requires — one consumer calling `next()` at a time,
    /// which a drain does by construction.
    private final class ElementStream: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<[Backend.Element], any Error>.AsyncIterator

        init(_ stream: AsyncThrowingStream<[Backend.Element], any Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> [Backend.Element]? {
            try await iterator.next()
        }
    }

    private struct LiveSample {
        let id: UUID
        let startDate: Date
        let endDate: Date
        let stream: ElementStream
        var offset: Int
        /// Elements pulled from the stream but not yet written.
        var buffer: [Backend.Element] = []
        var isExhausted = false
    }

    private let shape: SeriesShape
    private let backend: Backend
    private let encoder: HealthSampleEncoder
    private var live: LiveSample?

    public init(
        shape: SeriesShape,
        backend: Backend,
        encoder: HealthSampleEncoder = HealthSampleEncoder()
    ) {
        self.shape = shape
        self.backend = backend
        self.encoder = encoder
    }

    public func changes(
        after token: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        guard limit > 0 else {
            throw HealthKitSourceError.invalidLimit
        }

        let anchor = try SeriesAnchor.decode(token)
        if let pending = anchor.pendingSample {
            return try await continueSample(pending, from: anchor)
        }
        return try await beginNextSample(from: anchor)
    }

    // MARK: - Advancing through samples

    private func beginNextSample(
        from anchor: SeriesAnchor
    ) async throws -> HealthChangeBatch {
        let page = try await backend.nextPage(after: anchor.healthKitAnchor)

        var changes: [HealthChange] = page.deletions.map {
            .delete(CapturedHealthDeletion(id: $0, type: shape.typeKey))
        }

        guard let header = page.header else {
            return HealthChangeBatch(
                changes: changes,
                proposedAnchor: try SeriesAnchor(
                    healthKitAnchor: page.anchor
                ).token()
            )
        }

        changes.append(
            try SeriesEncoding.headerChange(shape: shape, header: header)
        )

        // The header becomes durable before a single element is read, so a
        // kill between the two replays only the elements.
        return HealthChangeBatch(
            changes: changes,
            proposedAnchor: try SeriesAnchor(
                healthKitAnchor: page.anchor,
                pendingSample: header.id,
                deliveredElements: 0
            ).token()
        )
    }

    private func continueSample(
        _ sampleID: UUID,
        from anchor: SeriesAnchor
    ) async throws -> HealthChangeBatch {
        var sample: LiveSample
        if let live, live.id == sampleID, live.offset == anchor.deliveredElements {
            sample = live
        } else {
            guard let reopened = try await reopen(
                sampleID,
                skipping: anchor.deliveredElements
            ) else {
                // The sample changed between pages. Recording that is the only
                // honest option: its header is already in the export, so saying
                // nothing would leave a recording that simply stops.
                live = nil
                return HealthChangeBatch(
                    changes: [
                        .upsert(
                            CapturedHealthObject(
                                id: sampleID,
                                type: shape.typeKey,
                                canonicalPayload: try encoder.encodeEncodingFailure(
                                    id: sampleID,
                                    typeIdentifier: shape.typeIdentifier,
                                    message: "The sample changed in Health while it was being read."
                                )
                            )
                        )
                    ],
                    proposedAnchor: try SeriesAnchor(
                        healthKitAnchor: anchor.healthKitAnchor
                    ).token()
                )
            }
            sample = reopened
        }
        // Dropped before a single element is pulled, and only put back once
        // the page is built. The stream is a reference: reading from the local
        // copy advances the one the actor is holding, so a throw part-way
        // through would leave a cursor that says offset 500 pointing at a
        // stream already past 1,000 — and the next page would skip the
        // difference without anything noticing. Forgetting it costs a re-open
        // after a failure and cannot lose an element.
        live = nil

        var changes: [HealthChange] = []
        while changes.count < shape.recordsPerPage {
            try await fill(&sample, upTo: shape.elementsPerRecord)
            let take = min(shape.elementsPerRecord, sample.buffer.count)
            // A short record is only correct at the end of a sample. Anywhere
            // else it would shift every later page's offset and change the
            // identifiers a receiver recognises a replay by.
            let isFullRecord = take == shape.elementsPerRecord
            guard take > 0, isFullRecord || sample.isExhausted else {
                break
            }

            let elements = Array(sample.buffer.prefix(take))
            sample.buffer.removeFirst(take)
            changes.append(
                try SeriesEncoding.elementsChange(
                    shape: shape,
                    sample: sample.id,
                    offset: sample.offset,
                    elements: elements,
                    sampleStart: sample.startDate,
                    sampleEnd: sample.endDate
                )
            )
            sample.offset += take
        }

        let isFinished = sample.isExhausted && sample.buffer.isEmpty
        if isFinished {
            changes.append(
                try SeriesEncoding.endChange(
                    shape: shape,
                    sample: sample.id,
                    elementCount: sample.offset,
                    sampleStart: sample.startDate,
                    sampleEnd: sample.endDate
                )
            )
            live = nil
        } else {
            live = sample
        }

        return HealthChangeBatch(
            changes: changes,
            proposedAnchor: try SeriesAnchor(
                healthKitAnchor: anchor.healthKitAnchor,
                pendingSample: isFinished ? nil : sample.id,
                deliveredElements: isFinished ? 0 : sample.offset
            ).token()
        )
    }

    /// Pulls from the stream until the buffer can fill a record, or the sample
    /// runs out.
    ///
    /// The cancellation check is the difference between a checkpoint and a
    /// truncation. `AsyncThrowingStream` answers a cancelled read by *ending
    /// the stream* rather than by throwing, so a `nil` here means either "the
    /// sample is finished" or "this task was cancelled", and the two lead
    /// opposite ways: one seals the sample with an end marker and moves the
    /// cursor past it, the other must leave the cursor exactly where it was.
    /// Cancellation is not an edge case — the background scheduler cancels on
    /// purpose when iOS takes its time back, precisely so the next attempt
    /// resumes rather than starting over.
    private func fill(_ sample: inout LiveSample, upTo count: Int) async throws {
        while sample.buffer.count < count, !sample.isExhausted {
            guard let batch = try await sample.stream.next() else {
                try Task.checkCancellation()
                sample.isExhausted = true
                return
            }
            sample.buffer.append(contentsOf: batch)
        }
    }

    private func reopen(
        _ sampleID: UUID,
        skipping delivered: Int
    ) async throws -> LiveSample? {
        guard let facts = try await backend.facts(id: sampleID) else {
            return nil
        }

        var sample = LiveSample(
            id: sampleID,
            startDate: facts.startDate,
            endDate: facts.endDate,
            stream: ElementStream(backend.elements(for: sampleID)),
            offset: 0
        )

        // Health cannot start a stream part-way through, so the elements that
        // are already durable are read and dropped. That happens once, after
        // an interruption, and never on the ordinary path where the stream
        // stays open across pages.
        while sample.offset < delivered, !sample.isExhausted {
            guard let batch = try await sample.stream.next() else {
                // Cancellation ends the stream rather than throwing, and
                // mistaking it for the end of the sample here would report a
                // sample that shrank when nothing shrank.
                try Task.checkCancellation()
                sample.isExhausted = true
                break
            }
            let remaining = delivered - sample.offset
            if batch.count <= remaining {
                sample.offset += batch.count
            } else {
                sample.buffer = Array(batch.dropFirst(remaining))
                sample.offset = delivered
            }
        }
        // The stream ended before reaching the recorded position, so the sample
        // shrank underneath the cursor. Continuing would write elements under
        // offsets that no longer mean what they meant.
        guard sample.offset == delivered else {
            return nil
        }
        return sample
    }
}
