import Foundation
import HozzCore

/// Writes the readings behind a quantity aggregate, a bounded piece at a time.
///
/// One `HKQuantitySample` can stand for thousands of readings, so a sample is
/// expanded across several pages and the cursor records how far into it Hozz
/// has got. The rules are the ones ``SeriesReader`` already follows for routes
/// and recordings, for the same reasons:
///
/// - Readings are addressed by **absolute offset**, never by however far this
///   particular pass happened to get, so a page replayed after an interruption
///   carries the same identifier and the same bytes as the page it replaces.
/// - A short record is only written at the very end of a sample. Anywhere else
///   it would shift every later offset and hand a receiver the same readings
///   under new identifiers.
/// - The stream stays open between pages, so the ordinary path reads each
///   reading exactly once. A relaunch has no stream to continue, so it re-opens
///   the sample and skips what is already durable — paying a re-read once,
///   after an interruption, rather than on every page.
///
/// What is *not* like the other series: there is no header. The parent sample
/// is already in the export as an ordinary quantity record carrying `count` and
/// `aggregatesSeries`, and the reading pages point back at it.
public actor QuantitySeriesExpander {
    /// Holds the live iterator by reference so it can be advanced without the
    /// actor's stored state being mutated across an `await`.
    ///
    /// `@unchecked Sendable` is the honest label rather than a shortcut: the
    /// storage behind an `AsyncThrowingStream` is already thread-safe, and this
    /// box never leaves the actor, so the only rule it relies on is the one
    /// that stream already requires — one consumer calling `next()` at a time,
    /// which a drain does by construction.
    private final class ReadingStream: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<[QuantityReading], any Error>
            .AsyncIterator

        init(_ stream: AsyncThrowingStream<[QuantityReading], any Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> [QuantityReading]? {
            try await iterator.next()
        }
    }

    private struct LiveSeries {
        let type: HealthTypeKey
        let id: UUID
        let startDate: Date
        let endDate: Date
        let stream: ReadingStream
        var offset: Int
        /// Readings pulled from the stream but not yet written.
        var buffer: [QuantityReading] = []
        var isExhausted = false
    }

    /// One page of expansion: what to write, and where that leaves the cursor.
    public struct Expansion: Sendable {
        public let changes: [HealthChange]
        public let anchor: QuantityAnchor
        /// Samples whose readings could not be had, written into the export as
        /// explicit failures. Counted so the run's own tally of encoding
        /// problems matches what the export actually contains.
        public let failures: Int

        public init(
            changes: [HealthChange],
            anchor: QuantityAnchor,
            failures: Int = 0
        ) {
            self.changes = changes
            self.anchor = anchor
            self.failures = failures
        }
    }

    private let backend: any QuantitySeriesBackend
    private let encoder: HealthSampleEncoder
    private var live: LiveSeries?

    public init(
        backend: any QuantitySeriesBackend,
        encoder: HealthSampleEncoder = HealthSampleEncoder()
    ) {
        self.backend = backend
        self.encoder = encoder
    }

    /// Writes as much of the cursor's head sample as one page allows.
    ///
    /// - Parameter recordLimit: Records the caller can still take. The end
    ///   marker may be written on top of it, because a sample that has just
    ///   finished must say so in the same transaction that records it as
    ///   finished — deferring it to the next page would leave the cursor
    ///   claiming a sample is done while the export never says it is.
    public func expand(
        from anchor: QuantityAnchor,
        type: HealthTypeKey,
        unit: String,
        recordLimit: Int
    ) async throws -> Expansion {
        guard let sampleID = anchor.pendingSample else {
            return Expansion(changes: [], anchor: anchor)
        }
        let shape = QuantitySeriesEncoding.shape(for: type.rawValue)

        var series: LiveSeries
        if
            let live,
            live.type == type,
            live.id == sampleID,
            live.offset == anchor.deliveredReadings
        {
            series = live
        } else {
            guard
                let reopened = try await reopen(
                    sampleID,
                    type: type,
                    unit: unit,
                    skipping: anchor.deliveredReadings
                )
            else {
                // The sample changed in Health between pages. Saying so is the
                // only honest option: its aggregate is already in the export
                // promising `count` readings, so staying silent would leave a
                // promise nothing ever answers.
                live = nil
                return try unreadable(
                    sampleID,
                    type: type,
                    shape: shape,
                    anchor: anchor,
                    // Deliberately not "the sample changed in Health". Health
                    // gives the same silence for a sample the user deleted, a
                    // sample that was rewritten, and a type whose permission
                    // was withdrawn, and this cannot tell them apart. Naming
                    // one of them would be a guess presented as a fact — and
                    // the commonest of the three, an ordinary deletion, is not
                    // something to alarm anyone about.
                    message: "Health no longer offers this sample, so its readings are not in this export. It may have been deleted, changed, or permission to read this type may have been withdrawn."
                )
            }
            series = reopened
        }
        // Dropped before a single reading is pulled, and only put back once
        // the page is built. The stream is a reference: reading from the local
        // copy advances the one the actor is holding, so a throw part-way
        // through would leave a cursor that says offset 500 pointing at a
        // stream already past 1,000 — and the next page would skip the
        // difference without anything noticing. Forgetting it costs a re-open
        // after a failure and cannot lose a reading.
        live = nil

        let budget = max(1, min(recordLimit, shape.recordsPerPage))
        var changes: [HealthChange] = []
        while changes.count < budget {
            try await fill(&series, upTo: shape.elementsPerRecord)
            let take = min(shape.elementsPerRecord, series.buffer.count)
            let isFullRecord = take == shape.elementsPerRecord
            guard take > 0, isFullRecord || series.isExhausted else {
                break
            }

            let readings = Array(series.buffer.prefix(take))
            series.buffer.removeFirst(take)
            changes.append(
                try SeriesEncoding.elementsChange(
                    shape: shape,
                    sample: series.id,
                    offset: series.offset,
                    elements: readings,
                    sampleStart: series.startDate,
                    sampleEnd: series.endDate,
                    // Carried once per page rather than on each of five
                    // hundred readings, and it is the same unit the parent
                    // aggregate is written in, so the two compare without
                    // conversion.
                    extra: ["unit": unit]
                )
            )
            series.offset += take
        }

        let isFinished = series.isExhausted && series.buffer.isEmpty
        if isFinished {
            // Nothing reaches the queue that does not claim at least two
            // readings, so a sample that enumerates none has not been read —
            // it is not a series that happens to be empty. Sealing it with an
            // end marker would tell a receiver the sample is complete and has
            // no detail behind it, and nothing would ever look again. The
            // cursor still moves past it, because a sample that cannot be read
            // would otherwise block every later one of its type; the record
            // says plainly which sample it was.
            guard series.offset > 0 else {
                live = nil
                return try unreadable(
                    series.id,
                    type: type,
                    shape: shape,
                    anchor: anchor,
                    message: "Health returned no readings for a sample that reports more than one."
                )
            }
            changes.append(
                try SeriesEncoding.endChange(
                    shape: shape,
                    sample: series.id,
                    elementCount: series.offset,
                    sampleStart: series.startDate,
                    sampleEnd: series.endDate
                )
            )
            live = nil
        } else {
            live = series
        }

        return Expansion(
            changes: changes,
            anchor: isFinished
                ? anchor.advancedPastPendingSample()
                : anchor.advanced(toReading: series.offset)
        )
    }

    /// Records that a sample's readings could not be had, and moves on.
    ///
    /// The identifier is derived rather than the sample's own, because that
    /// one belongs to the aggregate record: writing the failure under it would
    /// replace a reading Hozz does have with a note about one it does not.
    private func unreadable(
        _ sampleID: UUID,
        type: HealthTypeKey,
        shape: SeriesShape,
        anchor: QuantityAnchor,
        message: String
    ) throws -> Expansion {
        let failureID = HealthSampleEncoder.encodingFailureID(
            sourceRecordID: sampleID,
            typeIdentifier: type.rawValue
        )
        return Expansion(
            changes: [
                .upsert(
                    CapturedHealthObject(
                        id: failureID,
                        type: type,
                        canonicalPayload: try encoder.encodeEncodingFailure(
                            id: sampleID,
                            typeIdentifier: type.rawValue,
                            message: message,
                            resolutionCanonicalID:
                                SeriesEncoding.completionCanonicalID(
                                    shape: shape,
                                    sample: sampleID
                                )
                        )
                    )
                )
            ],
            anchor: anchor.advancedPastPendingSample(),
            failures: 1
        )
    }

    /// Pulls from the stream until the buffer can fill a record, or the sample
    /// runs out.
    ///
    /// The cancellation check is the difference between a checkpoint and a
    /// truncation. `AsyncThrowingStream` answers a cancelled read by *ending
    /// the stream* rather than by throwing, so a `nil` here means either "the
    /// sample is finished" or "this task was cancelled", and the two lead
    /// opposite ways: one seals the sample and drops it from the queue, the
    /// other must leave the cursor exactly where it was. Cancellation is not
    /// an edge case — the background scheduler cancels on purpose when iOS
    /// takes its time back, precisely so the next attempt resumes.
    private func fill(_ series: inout LiveSeries, upTo count: Int) async throws {
        while series.buffer.count < count, !series.isExhausted {
            guard let batch = try await series.stream.next() else {
                try Task.checkCancellation()
                series.isExhausted = true
                return
            }
            series.buffer.append(contentsOf: batch)
        }
    }

    private func reopen(
        _ sampleID: UUID,
        type: HealthTypeKey,
        unit: String,
        skipping delivered: Int
    ) async throws -> LiveSeries? {
        guard let facts = try await backend.facts(for: sampleID, type: type) else {
            return nil
        }

        var series = LiveSeries(
            type: type,
            id: sampleID,
            startDate: facts.startDate,
            endDate: facts.endDate,
            stream: ReadingStream(
                backend.readings(for: sampleID, type: type, unit: unit)
            ),
            offset: 0
        )

        // Health cannot start a series part-way through, so the readings that
        // are already durable are read and dropped. That happens once, after
        // an interruption, and never on the ordinary path where the stream
        // stays open across pages.
        while series.offset < delivered, !series.isExhausted {
            guard let batch = try await series.stream.next() else {
                // Cancellation ends the stream rather than throwing, and
                // mistaking it for the end of the sample here would report a
                // sample that shrank when nothing shrank.
                try Task.checkCancellation()
                series.isExhausted = true
                break
            }
            let remaining = delivered - series.offset
            if batch.count <= remaining {
                series.offset += batch.count
            } else {
                series.buffer = Array(batch.dropFirst(remaining))
                series.offset = delivered
            }
        }
        // The stream ended before reaching the recorded position, so the
        // sample shrank underneath the cursor. Continuing would write readings
        // under offsets that no longer mean what they meant.
        guard series.offset == delivered else {
            return nil
        }
        return series
    }
}
