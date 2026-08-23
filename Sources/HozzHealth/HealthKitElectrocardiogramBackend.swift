import Foundation
import HealthKit
import HozzCore

/// The real electrocardiogram backend: HealthKit queries, and nothing else.
///
/// Everything about paging, offsets, and replay lives in ``SeriesReader``.
/// This type only turns Health's callbacks into `Sendable` values, so no
/// `HKSample` ever leaves HealthKit's own queue.
public struct HealthKitElectrocardiogramBackend: SeriesBackend {
    // Safe to share: `HKHealthStore` documents its queries as usable from any
    // thread, and this type only ever executes them.
    private nonisolated(unsafe) let healthStore: HKHealthStore
    private let encoder: HealthSampleEncoder

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        encoder: HealthSampleEncoder = HealthSampleEncoder()
    ) {
        self.healthStore = healthStore
        self.encoder = encoder
    }

    public func nextPage(after anchor: Data?) async throws -> SeriesPage {
        let startAnchor = try HealthKitAnchorCoding.anchor(
            for: anchor.map { AnchorToken(data: $0) }
        )
        let encoder = encoder

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.electrocardiogramType(),
                predicate: nil,
                anchor: startAnchor,
                limit: 1
            ) { _, samples, deletions, newAnchor, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: ElectrocardiogramEncoding.typeIdentifier
                        )
                    )
                    return
                }
                guard let newAnchor else {
                    continuation.resume(
                        throwing: HealthKitSourceError.missingAnchor(
                            ElectrocardiogramEncoding.typeIdentifier
                        )
                    )
                    return
                }

                do {
                    let token = try HealthKitAnchorCoding.token(for: newAnchor)
                    var header: SeriesHeader?
                    if let sample = samples?.first as? HKElectrocardiogram {
                        header = SeriesHeader(
                            id: sample.uuid,
                            startDate: sample.startDate,
                            endDate: sample.endDate,
                            basePayload: try ElectrocardiogramEncoding.basePayload(
                                try encoder.encodeBaseFields(sample: sample),
                                classification: Self.classification(sample.classification),
                                symptomsStatus: Self.symptoms(sample.symptomsStatus),
                                averageHeartRate: sample.averageHeartRate?
                                    .doubleValue(
                                        for: HKUnit.count()
                                            .unitDivided(by: .minute())
                                    ),
                                samplingFrequencyHertz: sample.samplingFrequency?
                                    .doubleValue(for: .hertz()),
                                numberOfVoltageMeasurements: sample
                                    .numberOfVoltageMeasurements
                            )
                        )
                    }
                    continuation.resume(
                        returning: SeriesPage(
                            header: header,
                            deletions: (deletions ?? []).map(\.uuid),
                            anchor: token.data
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            healthStore.execute(query)
        }
    }

    public func facts(id: UUID) async throws -> SeriesFacts? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.electrocardiogramType(),
                predicate: HKQuery.predicateForObject(with: id),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: ElectrocardiogramEncoding.typeIdentifier
                        )
                    )
                    return
                }
                guard let sample = samples?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: SeriesFacts(
                        startDate: sample.startDate,
                        endDate: sample.endDate
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    /// The recording's voltages, delivered one at a time by HealthKit and
    /// gathered into small batches before they cross into the reader.
    ///
    /// `AsyncThrowingStream` is used rather than hopping each reading onto an
    /// actor, because its yields are ordered. Delivering readings through
    /// unordered tasks would silently scramble a heartbeat.
    public func elements(
        for sampleID: UUID
    ) -> AsyncThrowingStream<[ECGVoltage], any Error> {
        let healthStore = healthStore

        return AsyncThrowingStream { continuation in
            let lookup = HKSampleQuery(
                sampleType: HKObjectType.electrocardiogramType(),
                predicate: HKQuery.predicateForObject(with: sampleID),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let ecg = samples?.first as? HKElectrocardiogram else {
                    continuation.finish()
                    return
                }

                let start = ecg.startDate
                // HealthKit hands over one reading per callback, so they are
                // gathered before crossing, rather than paying a yield per
                // reading for fifteen thousand of them.
                let batch = VoltageBatch()
                let voltageQuery = HKElectrocardiogramQuery(ecg) { _, result in
                    switch result {
                    case .measurement(let measurement):
                        let volts = measurement
                            .quantity(for: .appleWatchSimilarToLeadI)?
                            .doubleValue(for: .volt())
                        if let ready = batch.append(
                            ECGVoltage(
                                timeSinceStart: measurement.timeSinceSampleStart,
                                volts: volts,
                                timestamp: start.addingTimeInterval(
                                    measurement.timeSinceSampleStart
                                )
                            )
                        ) {
                            continuation.yield(ready)
                        }
                    case .done:
                        if let remainder = batch.drain() {
                            continuation.yield(remainder)
                        }
                        continuation.finish()
                    case .error(let error):
                        continuation.finish(throwing: error)
                    @unknown default:
                        // An outcome Hozz does not recognise is a failure, not
                        // a quiet end: treating it as `done` would publish a
                        // half-read recording as a whole one.
                        continuation.finish(
                            throwing: HealthKitSourceError.unsupportedType(
                                ElectrocardiogramEncoding.typeIdentifier
                            )
                        )
                    }
                }
                healthStore.execute(voltageQuery)
            }
            healthStore.execute(lookup)
        }
    }

    /// Gathers single readings into batches. HealthKit calls the voltage
    /// handler serially for one query, so a plain lock is all this needs.
    private final class VoltageBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [ECGVoltage] = []
        private let size = 256

        func append(_ voltage: ECGVoltage) -> [ECGVoltage]? {
            lock.lock()
            defer { lock.unlock() }
            pending.append(voltage)
            guard pending.count >= size else {
                return nil
            }
            let ready = pending
            pending.removeAll(keepingCapacity: true)
            return ready
        }

        func drain() -> [ECGVoltage]? {
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

    static func classification(
        _ value: HKElectrocardiogram.Classification
    ) -> ECGClassification {
        let name: String = switch value {
        case .notSet: "notSet"
        case .sinusRhythm: "sinusRhythm"
        case .atrialFibrillation: "atrialFibrillation"
        case .inconclusiveLowHeartRate: "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: "inconclusiveHighHeartRate"
        case .inconclusivePoorReading: "inconclusivePoorReading"
        case .inconclusiveOther: "inconclusiveOther"
        case .unrecognized: "unrecognized"
        @unknown default: "unrecognisedByHozz"
        }
        return ECGClassification(name: name, rawValue: value.rawValue)
    }

    static func symptoms(
        _ value: HKElectrocardiogram.SymptomsStatus
    ) -> ECGClassification {
        let name: String = switch value {
        case .notSet: "notSet"
        case .none: "none"
        case .present: "present"
        @unknown default: "unrecognisedByHozz"
        }
        return ECGClassification(name: name, rawValue: value.rawValue)
    }
}
