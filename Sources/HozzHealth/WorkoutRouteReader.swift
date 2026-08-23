import Foundation
import HozzCore

/// What a route stream needs from Health, kept behind a protocol so the part
/// that can lose or duplicate points can be tested without a device that has
/// any rides on it.
public protocol WorkoutRouteBackend: Sendable {
    /// Reads exactly one route sample, so a route is never in memory beside
    /// another one's points.
    func nextRoutePage(after anchor: Data?) async throws -> WorkoutRoutePage

    /// The route's start and end, used when re-opening a route after a
    /// relaunch. `nil` means the route is no longer in Health.
    func routeFacts(id: UUID) async throws -> WorkoutRouteFacts?

    /// The route's points, in the batches Health chooses to deliver them.
    func locations(for routeID: UUID) -> AsyncThrowingStream<[RouteLocation], any Error>

    func resolveWorkout(
        routeID: UUID,
        start: Date,
        end: Date
    ) async -> RouteWorkoutLink
}

public struct WorkoutRoutePage: Sendable {
    public let header: WorkoutRouteEncoding.Header?
    public let deletions: [UUID]
    public let anchor: Data

    public init(
        header: WorkoutRouteEncoding.Header?,
        deletions: [UUID],
        anchor: Data
    ) {
        self.header = header
        self.deletions = deletions
        self.anchor = anchor
    }
}

public struct WorkoutRouteFacts: Sendable {
    public let startDate: Date
    public let endDate: Date

    public init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// Drains workout routes, streaming each route's locations rather than
/// collecting them.
///
/// A route is one HealthKit sample whose real content is somewhere else: the
/// points arrive in batches and a long ride holds hundreds of thousands of
/// them. Handing a route over as a single object would put the whole ride in
/// memory in a process iOS is willing to kill for exactly that, so a route is
/// drained across several pages and the cursor records how far into it Hozz
/// has got.
///
/// The stream stays open between pages, which keeps the ordinary path to a
/// single read of each point. A relaunch has no stream to continue, so it
/// re-opens the route and skips what is already durable — paying a re-read
/// once, after an interruption, rather than on every page.
public actor WorkoutRouteReader {
    /// Holds the live iterator by reference so it can be advanced without the
    /// actor's stored state being mutated across an `await`.
    ///
    /// `@unchecked Sendable` is the honest label rather than a shortcut: the
    /// storage behind an `AsyncThrowingStream` is already thread-safe, and this
    /// box never leaves the actor, so the only rule it relies on is the one
    /// that stream already requires — one consumer calling `next()` at a time,
    /// which a drain does by construction.
    private final class LocationStream: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<[RouteLocation], any Error>.AsyncIterator

        init(_ stream: AsyncThrowingStream<[RouteLocation], any Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> [RouteLocation]? {
            try await iterator.next()
        }
    }

    private struct LiveRoute {
        let id: UUID
        let startDate: Date
        let endDate: Date
        let stream: LocationStream
        var offset: Int
        /// Points pulled from the stream but not yet written.
        var buffer: [RouteLocation] = []
        var isExhausted = false
    }

    private let backend: any WorkoutRouteBackend
    private let encoder: HealthSampleEncoder
    private var live: LiveRoute?

    public init(
        backend: any WorkoutRouteBackend,
        encoder: HealthSampleEncoder = HealthSampleEncoder()
    ) {
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

        let anchor = try WorkoutRouteAnchor.decode(token)
        if let pending = anchor.pendingRoute {
            return try await continueRoute(pending, from: anchor)
        }
        return try await beginNextRoute(from: anchor)
    }

    // MARK: - Advancing through routes

    private func beginNextRoute(
        from anchor: WorkoutRouteAnchor
    ) async throws -> HealthChangeBatch {
        let page = try await backend.nextRoutePage(after: anchor.healthKitAnchor)

        var changes: [HealthChange] = page.deletions.map {
            .delete(
                CapturedHealthDeletion(
                    id: $0,
                    type: WorkoutRouteEncoding.typeKey
                )
            )
        }

        guard let header = page.header else {
            return HealthChangeBatch(
                changes: changes,
                proposedAnchor: try WorkoutRouteAnchor(
                    healthKitAnchor: page.anchor
                ).token()
            )
        }

        let link = await backend.resolveWorkout(
            routeID: header.id,
            start: header.startDate,
            end: header.endDate
        )
        changes.append(
            try WorkoutRouteEncoding.headerChange(
                id: header.id,
                basePayload: header.basePayload,
                workout: link
            )
        )

        // The header becomes durable before a single point is read, so a kill
        // between the two replays only the points.
        return HealthChangeBatch(
            changes: changes,
            proposedAnchor: try WorkoutRouteAnchor(
                healthKitAnchor: page.anchor,
                pendingRoute: header.id,
                deliveredLocations: 0
            ).token()
        )
    }

    private func continueRoute(
        _ routeID: UUID,
        from anchor: WorkoutRouteAnchor
    ) async throws -> HealthChangeBatch {
        var route: LiveRoute
        if let live, live.id == routeID, live.offset == anchor.deliveredLocations {
            route = live
        } else {
            guard let reopened = try await reopen(
                routeID,
                skipping: anchor.deliveredLocations
            ) else {
                // The route went away between pages. Recording that is the only
                // honest option: its header is already in the export, so saying
                // nothing would leave a route that simply stops.
                live = nil
                return HealthChangeBatch(
                    changes: [
                        .upsert(
                            CapturedHealthObject(
                                id: routeID,
                                type: WorkoutRouteEncoding.typeKey,
                                canonicalPayload: try encoder.encodeEncodingFailure(
                                    id: routeID,
                                    typeIdentifier: WorkoutRouteEncoding.typeIdentifier,
                                    message: "The route changed in Health while it was being read."
                                )
                            )
                        )
                    ],
                    proposedAnchor: try WorkoutRouteAnchor(
                        healthKitAnchor: anchor.healthKitAnchor
                    ).token()
                )
            }
            route = reopened
        }

        var changes: [HealthChange] = []
        while changes.count < WorkoutRouteEncoding.recordsPerPage {
            try await fill(&route, upTo: WorkoutRouteEncoding.locationsPerRecord)
            let take = min(
                WorkoutRouteEncoding.locationsPerRecord,
                route.buffer.count
            )
            // A short record is only correct at the end of a route. Anywhere
            // else it would shift every later page's offset and change the
            // identifiers a receiver recognises a replay by.
            let isFullRecord = take == WorkoutRouteEncoding.locationsPerRecord
            guard take > 0, isFullRecord || route.isExhausted else {
                break
            }

            let locations = Array(route.buffer.prefix(take))
            route.buffer.removeFirst(take)
            changes.append(
                try WorkoutRouteEncoding.locationsChange(
                    route: route.id,
                    offset: route.offset,
                    locations: locations,
                    routeStart: route.startDate,
                    routeEnd: route.endDate
                )
            )
            route.offset += take
        }

        let isFinished = route.isExhausted && route.buffer.isEmpty
        if isFinished {
            changes.append(
                try WorkoutRouteEncoding.endChange(
                    route: route.id,
                    locationCount: route.offset,
                    routeStart: route.startDate,
                    routeEnd: route.endDate
                )
            )
            live = nil
        } else {
            live = route
        }

        return HealthChangeBatch(
            changes: changes,
            proposedAnchor: try WorkoutRouteAnchor(
                healthKitAnchor: anchor.healthKitAnchor,
                pendingRoute: isFinished ? nil : route.id,
                deliveredLocations: isFinished ? 0 : route.offset
            ).token()
        )
    }

    /// Pulls from the stream until the buffer can fill a record, or the route
    /// runs out. Never holds more than one record's worth plus one batch.
    private func fill(_ route: inout LiveRoute, upTo count: Int) async throws {
        while route.buffer.count < count, !route.isExhausted {
            guard let batch = try await route.stream.next() else {
                route.isExhausted = true
                return
            }
            route.buffer.append(contentsOf: batch)
        }
    }

    private func reopen(
        _ routeID: UUID,
        skipping delivered: Int
    ) async throws -> LiveRoute? {
        guard let facts = try await backend.routeFacts(id: routeID) else {
            return nil
        }

        var route = LiveRoute(
            id: routeID,
            startDate: facts.startDate,
            endDate: facts.endDate,
            stream: LocationStream(backend.locations(for: routeID)),
            offset: 0
        )

        // Health cannot start a route part-way through, so points that are
        // already durable are read and dropped. That happens once, after an
        // interruption, and never on the ordinary path where the stream stays
        // open across pages.
        while route.offset < delivered, !route.isExhausted {
            guard let batch = try await route.stream.next() else {
                route.isExhausted = true
                break
            }
            let remaining = delivered - route.offset
            if batch.count <= remaining {
                route.offset += batch.count
            } else {
                route.buffer = Array(batch.dropFirst(remaining))
                route.offset = delivered
            }
        }
        // The stream ended before reaching the recorded position, so the route
        // shrank underneath the cursor. Continuing would write points under
        // offsets that no longer mean what they meant.
        guard route.offset == delivered else {
            return nil
        }
        return route
    }
}
