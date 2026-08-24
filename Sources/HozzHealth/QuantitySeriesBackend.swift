import Foundation
import HozzCore

/// What expanding a quantity series needs from Health.
///
/// Kept behind a protocol for a reason the other series backends did not have:
/// a sample with `count > 1` cannot be built in a test at all. `HKQuantity`
/// samples are immutable value objects that can be constructed freely, but a
/// *series* sample only exists once `HKQuantitySeriesSampleBuilder` has written
/// it into a store Health will accept writes to — which a unit test does not
/// have. Without this seam the offset arithmetic, the resume path, and the
/// exactly-once accounting would all be untestable, and they run in the code
/// path every one of Hozz's cursors depends on.
public protocol QuantitySeriesBackend: Sendable {
    /// The parent sample's start and end. `nil` means it is no longer in
    /// Health, which is the one answer that must not be confused with an
    /// empty series.
    func facts(for sample: UUID, type: HealthTypeKey) async throws -> SeriesFacts?

    /// The sample's readings, in ascending order, in whatever batches suit.
    ///
    /// Order is the whole contract. Offsets address readings by position, so a
    /// stream that returned them in a different order on a replay would give
    /// the same reading two identifiers and a receiver two copies of it.
    func readings(
        for sample: UUID,
        type: HealthTypeKey,
        unit: String
    ) -> AsyncThrowingStream<[QuantityReading], any Error>
}
