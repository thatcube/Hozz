import Foundation
import HealthKit
import HozzCore

/// The real quantity series backend: HealthKit queries, and nothing else.
///
/// Everything about offsets, paging, and replay lives in
/// ``QuantitySeriesExpander``. This type only turns Health's callbacks into
/// `Sendable` values, so no `HKSample` or `HKQuantity` ever leaves HealthKit's
/// own queue.
public struct HealthKitQuantitySeriesBackend: QuantitySeriesBackend {
    // Safe to share: `HKHealthStore` documents its queries as usable from any
    // thread, and this type only ever executes them.
    private nonisolated(unsafe) let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public func facts(
        for sample: UUID,
        type: HealthTypeKey
    ) async throws -> SeriesFacts? {
        guard let quantityType = Self.quantityType(for: type) else {
            throw HealthKitSourceError.unsupportedType(type.rawValue)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: HKQuery.predicateForObject(with: sample),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: type.rawValue
                        )
                    )
                    return
                }
                guard let found = samples?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: SeriesFacts(
                        startDate: found.startDate,
                        endDate: found.endDate
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    /// The sample's readings, delivered one at a time by HealthKit and
    /// gathered into small batches before they cross into the expander.
    ///
    /// `AsyncThrowingStream` is used rather than hopping each reading onto an
    /// actor, because its yields are ordered. Delivering readings through
    /// unordered tasks would scramble a series, and the offsets that address
    /// them would then name different readings on every run.
    ///
    /// The stream buffers without limit, and that is a decision rather than an
    /// oversight. `HKQuantitySeriesSampleQuery` has no way to be paused: it
    /// calls its handler as fast as it can until the sample is done, so
    /// whatever is not consumed is held. The bounded buffering policies both
    /// answer a full buffer by *discarding a reading*, which trades a memory
    /// bound for exactly the thing this whole design exists to prevent. So the
    /// bound is the sample's own length: paging keeps records and bytes per
    /// page small, but a sample that is open is a sample whose remaining
    /// readings are in memory. A reading is twenty-four bytes, so even a very
    /// long series is megabytes rather than tens of them — and the same is
    /// true of a route's locations and a recording's voltages today.
    public func readings(
        for sample: UUID,
        type: HealthTypeKey,
        unit: String
    ) -> AsyncThrowingStream<[QuantityReading], any Error> {
        let healthStore = healthStore
        guard let quantityType = Self.quantityType(for: type) else {
            return AsyncThrowingStream {
                $0.finish(
                    throwing: HealthKitSourceError.unsupportedType(type.rawValue)
                )
            }
        }
        let hkUnit = HKUnit(from: unit)

        return AsyncThrowingStream { continuation in
            let batch = ReadingBatch()
            let query = HKQuantitySeriesSampleQuery(
                quantityType: quantityType,
                // The readings of one named sample. There is no predicate for
                // "samples that are series", which is why this is reached from
                // the ordinary drain rather than being a type of its own.
                predicate: HKQuery.predicateForObject(with: sample)
            ) { _, quantity, dateInterval, _, done, error in
                if let error {
                    continuation.finish(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: type.rawValue
                        )
                    )
                    return
                }
                if let quantity, let dateInterval {
                    let ready = batch.append(
                        QuantityReading(
                            value: quantity.doubleValue(for: hkUnit),
                            startDate: dateInterval.start,
                            endDate: dateInterval.end
                        )
                    )
                    if let ready {
                        continuation.yield(ready)
                    }
                }
                if done {
                    if let remainder = batch.drain() {
                        continuation.yield(remainder)
                    }
                    continuation.finish()
                }
            }
            // A page stops part-way through a long series by design, and the
            // expander then abandons the stream. Without this, Health would go
            // on reading the rest of the sample into a continuation nobody is
            // listening to.
            continuation.onTermination = { _ in
                healthStore.stop(query)
            }
            healthStore.execute(query)
        }
    }

    static func quantityType(for type: HealthTypeKey) -> HKQuantityType? {
        HKObjectType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: type.rawValue)
        )
    }

    /// Gathers single readings into batches. HealthKit calls the quantity
    /// handler serially for one query, so a plain lock is all this needs.
    private final class ReadingBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [QuantityReading] = []
        private let size = 256

        func append(_ reading: QuantityReading) -> [QuantityReading]? {
            lock.lock()
            defer { lock.unlock() }
            pending.append(reading)
            guard pending.count >= size else {
                return nil
            }
            let ready = pending
            pending.removeAll(keepingCapacity: true)
            return ready
        }

        func drain() -> [QuantityReading]? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else {
                return nil
            }
            let ready = pending
            pending.removeAll(keepingCapacity: true)
            return ready
        }
    }
}
