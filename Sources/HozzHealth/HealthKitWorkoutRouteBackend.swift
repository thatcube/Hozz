import CoreLocation
import Foundation
import HealthKit
import HozzCore

/// The real ``WorkoutRouteBackend``: HealthKit queries, and nothing else.
///
/// Everything about paging, offsets, and replay lives in ``WorkoutRouteReader``.
/// This type only turns Health's callbacks into `Sendable` values, so no
/// `HKSample` or `CLLocation` ever leaves HealthKit's own queue.
public struct HealthKitWorkoutRouteBackend: WorkoutRouteBackend {
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

    public func nextRoutePage(after anchor: Data?) async throws -> WorkoutRoutePage {
        let startAnchor = try HealthKitAnchorCoding.anchor(
            for: anchor.map { AnchorToken(data: $0) }
        )
        let encoder = encoder

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKSeriesType.workoutRoute(),
                predicate: nil,
                anchor: startAnchor,
                limit: 1
            ) { _, samples, deletions, newAnchor, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: WorkoutRouteEncoding.typeIdentifier
                        )
                    )
                    return
                }
                guard let newAnchor else {
                    continuation.resume(
                        throwing: HealthKitSourceError.missingAnchor(
                            WorkoutRouteEncoding.typeIdentifier
                        )
                    )
                    return
                }

                do {
                    let token = try HealthKitAnchorCoding.token(for: newAnchor)
                    var header: WorkoutRouteEncoding.Header?
                    if let sample = samples?.first {
                        header = WorkoutRouteEncoding.Header(
                            id: sample.uuid,
                            startDate: sample.startDate,
                            endDate: sample.endDate,
                            basePayload: try encoder.encodeBaseFields(
                                sample: sample
                            )
                        )
                    }
                    continuation.resume(
                        returning: WorkoutRoutePage(
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

    public func routeFacts(id: UUID) async throws -> WorkoutRouteFacts? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObject(with: id),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: WorkoutRouteEncoding.typeIdentifier
                        )
                    )
                    return
                }
                guard let sample = samples?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: WorkoutRouteFacts(
                        startDate: sample.startDate,
                        endDate: sample.endDate
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    /// The route's points, delivered in the batches HealthKit chooses.
    ///
    /// `AsyncThrowingStream` is used rather than hopping each batch onto an
    /// actor, because its yields are ordered. Delivering batches through
    /// unordered tasks would silently scramble a ride.
    public func locations(
        for routeID: UUID
    ) -> AsyncThrowingStream<[RouteLocation], any Error> {
        let healthStore = healthStore

        return AsyncThrowingStream { continuation in
            let lookup = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObject(with: routeID),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let route = samples?.first as? HKWorkoutRoute else {
                    continuation.finish()
                    return
                }

                let routeQuery = HKWorkoutRouteQuery(
                    route: route
                ) { _, locations, done, error in
                    if let error {
                        continuation.finish(throwing: error)
                        return
                    }
                    if let locations, !locations.isEmpty {
                        // Converted here so no `CLLocation` leaves HealthKit's
                        // queue, and so the encoding is testable as values.
                        continuation.yield(locations.map(RouteLocation.init))
                    }
                    if done {
                        continuation.finish()
                    }
                }
                healthStore.execute(routeQuery)
            }
            healthStore.execute(lookup)
        }
    }

    /// Finds the workout a route belongs to, and says so only when HealthKit
    /// confirms it.
    ///
    /// There is no back-pointer from a route to its workout, so the candidates
    /// are workouts that overlap the route in time, and each is then asked
    /// whether this route is actually its own. Overlap alone would attach a
    /// ride to whatever else happened to be recorded at the same moment.
    public func resolveWorkout(
        routeID: UUID,
        start: Date,
        end: Date
    ) async -> RouteWorkoutLink {
        do {
            let candidates = try await overlappingWorkouts(start: start, end: end)
            guard !candidates.isEmpty else {
                return .unresolved(
                    reason: "No workout overlaps this route. Workouts may not be readable."
                )
            }
            for candidate in candidates {
                if try await workout(candidate.id, owns: routeID) {
                    return .resolved(
                        id: candidate.id,
                        activityType: candidate.activityType,
                        startDate: candidate.startDate,
                        endDate: candidate.endDate
                    )
                }
            }
            return .unresolved(reason: "No overlapping workout claims this route.")
        } catch {
            return .unresolved(
                reason: HealthKitFailure.classify(
                    error,
                    typeIdentifier: WorkoutRouteEncoding.typeIdentifier
                ).underlyingDescription
            )
        }
    }

    private struct WorkoutCandidate: Sendable {
        let id: UUID
        let activityType: UInt
        let startDate: Date
        let endDate: Date
    }

    private func overlappingWorkouts(
        start: Date,
        end: Date
    ) async throws -> [WorkoutCandidate] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(
                    withStart: start,
                    end: end,
                    options: []
                ),
                limit: 8,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let candidates = (samples ?? [])
                    .compactMap { $0 as? HKWorkout }
                    .map {
                        WorkoutCandidate(
                            id: $0.uuid,
                            activityType: $0.workoutActivityType.rawValue,
                            startDate: $0.startDate,
                            endDate: $0.endDate
                        )
                    }
                    // Ordered so the same route always resolves the same way.
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                continuation.resume(returning: candidates)
            }
            healthStore.execute(query)
        }
    }

    private func workout(_ workoutID: UUID, owns routeID: UUID) async throws -> Bool {
        let healthStore = healthStore

        return try await withCheckedThrowingContinuation { continuation in
            let lookup = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForObject(with: workoutID),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: false)
                    return
                }

                let confirm = HKSampleQuery(
                    sampleType: HKSeriesType.workoutRoute(),
                    predicate: NSCompoundPredicate(
                        andPredicateWithSubpredicates: [
                            HKQuery.predicateForObjects(from: workout),
                            HKQuery.predicateForObject(with: routeID)
                        ]
                    ),
                    limit: 1,
                    sortDescriptors: nil
                ) { _, routes, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: !(routes ?? []).isEmpty)
                }
                healthStore.execute(confirm)
            }
            healthStore.execute(lookup)
        }
    }
}

extension RouteLocation {
    init(_ location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            floor: location.floor?.level,
            isSimulatedBySoftware: location.sourceInformation?
                .isSimulatedBySoftware,
            isProducedByAccessory: location.sourceInformation?
                .isProducedByAccessory
        )
    }
}
