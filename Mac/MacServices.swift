import Foundation
import HozzDeliver
import HozzMCP
import HozzReceive
import HozzStore
import Observation
import os

/// Everything the Mac app needs, wired once.
///
/// The default path is deliberately zero-configuration: on first launch a token
/// is generated, the receiver starts, and the computer advertises itself on the
/// local network. The user never types an IP address, because that is the step
/// where setup usually fails — and a home IP changes without warning, so a
/// hand-typed one silently stops working days later.
@MainActor
@Observable
final class MacServices {
    nonisolated private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "mac"
    )

    enum Status: Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var summaries: [TypeSummary] = []
    private(set) var totalRecords = 0
    /// Facts about the person — date of birth, blood type — rather than
    /// measurements of them. Shown because they are the context that makes the
    /// measurements interpretable.
    private(set) var characteristics: [StoredCharacteristic] = []
    /// Records stored without being understood, which means this Mac is behind
    /// the phone. Nothing is lost, but it is worth being able to see.
    private(set) var unhandled: [UnhandledSummary] = []
    /// Records that were waiting to be understood and have since been read.
    /// Worth saying out loud: it is the visible proof that holding them was
    /// not the same as losing them.
    private(set) var promotedRecords = 0
    private(set) var events: [ReceiverEvent] = []
    private(set) var devices: [KnownDevice] = []
    private(set) var lastReceivedAt: Date?
    /// Whether this computer managed to tell the user's other devices about
    /// itself. Surfaced because a silent failure here looks exactly like the
    /// feature working, and leaves a computer that simply never appears.
    private(set) var sharedWithOtherDevices: Bool?

    private(set) var token = ""
    private(set) var computerName = ""

    // MARK: - Dashboard state

    /// The whole archive's extent, so an "all time" chart knows where to start.
    private(set) var archiveSpan: (earliest: Date, latest: Date)?
    private(set) var archiveDensity: [ArchiveDensityColumn] = []
    private(set) var overview: [HealthDomain: [IngestStore.MetricSnapshot]] = [:]
    private(set) var detail: TypeSeries?
    private(set) var distribution: [DistributionBucket]?
    private(set) var recent: [HealthRecord] = []
    private(set) var comparison: [ComparisonSeries] = []
    private(set) var comparisonTypes: [String] = []
    private(set) var workouts: [IngestStore.StoredWorkout] = []
    private(set) var electrocardiograms: [IngestStore.StoredElectrocardiogram] = []
    private(set) var waveform: IngestStore.Waveform?
    private(set) var moods: [IngestStore.StoredMoodEntry] = []
    private(set) var medications: [IngestStore.MedicationAdherence] = []

    /// The viewer's own calendar.
    ///
    /// A desktop dashboard is read in the room it is standing in, so days are
    /// the days of whoever is looking. Held in one place so every chart, axis
    /// label and coverage count uses the same one rather than each reaching for
    /// `.current` and quietly disagreeing at a boundary.
    let calendar = Calendar.current

    private var store: IngestStore?
    private var receiver: HealthReceiver?
    private var watcher: FolderIngestWatcher?
    private(set) var watchedFolder: URL?

    /// Where the received database actually lives.
    ///
    /// Surfaced because the MCP tool runs outside this app's sandbox and cannot
    /// derive it: the container path has to be handed over explicitly.
    private(set) var dataDirectory = URL(fileURLWithPath: "/")

    /// The address to give the phone, once the receiver is listening.
    ///
    /// The numeric address, not the `.local` name. Showing a name that the
    /// phone may be unable to resolve produces a setup that looks correct and
    /// silently never connects — and it is the address that gets published, so
    /// showing something different is confusing on top of being fragile.
    var endpointURL: String? {
        guard case .ready(let port) = status else {
            return nil
        }
        let host = LocalAddress.candidates().first ?? Self.localHostName()
        return "http://\(host):\(port)"
    }

    /// Deliberately does nothing.
    ///
    /// Everything this needs — opening the database, reading the token from the
    /// Keychain — is file and Security I/O, and this type is `@MainActor`. Doing
    /// any of it here blocks the main thread before the window is even drawn: a
    /// Keychain read that waits on a prompt leaves the app running with no
    /// window and no way to tell what happened.
    init() {}

    /// One assembled set of services, built off the main thread.
    private struct Assembled: @unchecked Sendable {
        let store: IngestStore
        let receiver: HealthReceiver
        let token: String
        let computerName: String
        let directory: URL
    }

    nonisolated private static func assemble() throws -> Assembled {
        // Deliberately the app's own storage rather than the app-group-aware
        // path: see StoreLocation.privateSupportDirectory.
        let directory = try StoreLocation.privateSupportDirectory()
            .appending(path: "Received", directoryHint: .isDirectory)
        let store = try IngestStore(directory: directory)
        let name = Host.current().localizedName ?? "This Mac"
        let token = try resolveToken()

        // Publish to the user's own iCloud Keychain so their phone already
        // knows the token and never has to be introduced to this computer.
        // Best-effort: without the shared-group entitlement or iCloud this does
        // nothing, and the phone falls back to pairing over the network.
        let shared = SharedReceiverStore(
            accessGroup: SharedReceiverStore.resolvedAccessGroup()
        )
        do {
            // Published without an address here; the port is not known until
            // the listener is ready, and republishing then fills it in.
            try shared.publish(
                SharedReceiver(name: "Hozz on \(name)", token: token)
            )
        } catch {
            // Not fatal — the phone can still pair over the network — but it is
            // logged, because a silent failure here looks identical to the
            // feature working and is otherwise undiagnosable.
            Self.log.error(
                "Could not publish this Mac to iCloud Keychain: \(error.localizedDescription, privacy: .public)"
            )
        }

        return Assembled(
            store: store,
            receiver: HealthReceiver(
                store: store,
                token: token,
                serviceName: "Hozz on \(name)"
            ),
            token: token,
            computerName: name,
            directory: directory
        )
    }

    func start() async {
        let assembled: Assembled
        do {
            assembled = try await Task.detached(priority: .userInitiated) {
                try Self.assemble()
            }.value
        } catch {
            // Shown in the UI and logged: "it just doesn't work" is impossible
            // to diagnose from a screenshot of a failure message alone.
            Self.log.error(
                "Hozz could not start: \(error.localizedDescription, privacy: .public)"
            )
            status = .failed(error.localizedDescription)
            return
        }

        let receiver = assembled.receiver
        store = assembled.store
        self.receiver = receiver
        token = assembled.token
        computerName = assembled.computerName
        dataDirectory = assembled.directory

        await receiver.onStateChange { [weak self] state in
            Task { @MainActor in
                self?.apply(state)
            }
        }
        await receiver.onEvent { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.events.insert(event, at: 0)
                if self.events.count > 100 {
                    self.events.removeLast()
                }
                if case .stored = event.outcome {
                    self.lastReceivedAt = event.at
                }
                await self.refresh()
            }
        }
        await receiver.start()
        await refresh()
    }

    /// Watches a folder the phone writes to.
    ///
    /// The path that asks nothing of the network. Receiving over the local
    /// network is faster when it works, but it needs the router not to isolate
    /// clients and the firewall to admit an app it does not recognise — neither
    /// of which the user can be expected to arrange. A file arrives however the
    /// user already syncs files, from anywhere, over any connection.
    func watchFolder(_ folder: URL) async {
        guard let store else {
            return
        }
        let watcher = self.watcher ?? FolderIngestWatcher(store: store)
        self.watcher = watcher
        await watcher.onEvent { [weak self] event in
            Task { @MainActor in
                self?.events.insert(event, at: 0)
                if case .stored = event.outcome {
                    self?.lastReceivedAt = event.at
                }
                await self?.refresh()
            }
        }
        await watcher.start(folder: folder)
        watchedFolder = folder
        UserDefaults.standard.set(folder.path, forKey: "watchedFolder")
        await refresh()
    }

    func stopWatchingFolder() async {
        await watcher?.stop()
        watchedFolder = nil
        UserDefaults.standard.removeObject(forKey: "watchedFolder")
    }

    func stop() async {
        await receiver?.stop()
        await watcher?.stop()
    }

    func refresh() async {
        guard let store else {
            return
        }
        do {
            summaries = try await store.summaries()
            totalRecords = try await store.totalRecordCount()
            characteristics = try await store.characteristics()
            unhandled = try await store.unhandledSummary()
            // Opening the store already re-read anything an older parser could
            // not. Running it again here is a no-op on a healthy receiver and
            // is what lets the count be shown after an in-place update.
            if let promotion = try? await store.promoteUnhandledRecords(),
               promotion.promoted > 0 {
                promotedRecords += promotion.promoted
                summaries = try await store.summaries()
                totalRecords = try await store.totalRecordCount()
                unhandled = try await store.unhandledSummary()
            }
            devices = try await store.devices()
            lastReceivedAt = devices.map(\.lastSeenAt).max()
        } catch {
            // A read failure is not worth interrupting the user over; the
            // counts simply stay as they were.
        }
    }

    func aggregate(
        type: String,
        bucket: BucketSize
    ) async -> [AggregateBucket] {
        guard let store else { return [] }
        return (try? await store.aggregate(type: type, bucket: bucket)) ?? []
    }

    // MARK: - Dashboards

    /// The range every dashboard is showing.
    ///
    /// Held here rather than in each view so the four screens agree, and so it
    /// can be chosen once from what the archive actually holds.
    var range: ChartRange = .month

    /// The columns a range asks for, in the viewer's own calendar.
    private func plan(for range: ChartRange) -> TimeBucketPlan {
        TimeBucketPlan.forRange(
            range,
            now: .now,
            earliest: archiveSpan?.earliest,
            calendar: calendar
        )
    }

    /// Everything the overview draws.
    ///
    /// Loaded in one hop across the actor boundary per section rather than one
    /// per chart. Each query aggregates in SQLite, so what crosses back is a few
    /// hundred columns rather than the 147,330 rows behind them.
    func loadOverview(range: ChartRange) async {
        guard let store else { return }
        if archiveSpan == nil {
            archiveSpan = try? await store.archiveSpan()
        }

        // Always the whole archive, whatever range the metrics are showing:
        // this chart's job is to put the sweep's shape on screen, and a
        // seven-day window of it would show nothing at all.
        let wholeArchive = TimeBucketPlan.forRange(
            .all,
            now: .now,
            earliest: archiveSpan?.earliest,
            calendar: calendar
        )
        archiveDensity = (try? await store.archiveDensity(plan: wholeArchive)) ?? []

        let plan = plan(for: range)
        var loaded: [HealthDomain: [IngestStore.MetricSnapshot]] = [:]
        for domain in HealthDomain.allCases {
            loaded[domain] = (try? await store.snapshots(
                types: domain.types,
                plan: plan
            )) ?? []
        }
        overview = loaded
    }

    func loadDetail(type: String, range: ChartRange) async {
        guard let store else { return }
        if archiveSpan == nil {
            archiveSpan = try? await store.archiveSpan()
        }
        let plan = plan(for: range)
        // Cleared first so a slow query never leaves the previous type's numbers
        // under the new type's name.
        detail = nil
        distribution = nil
        recent = []

        detail = try? await store.series(type: type, plan: plan)
        if let span = plan.span {
            distribution = try? await store.distribution(
                type: type,
                from: span.start,
                to: span.end
            )
        }
        recent = (try? await store.samples(type: type, limit: 8)) ?? []
    }

    /// Types worth offering for comparison.
    ///
    /// Anything with a number in it and more than a handful of records. A type
    /// with three samples cannot show a relationship with anything.
    var comparableTypes: [TypeSummary] {
        summaries
            .filter { $0.recordCount >= 10 }
            .sorted { left, right in
                HealthMeasure.measure(for: left.type, storedUnit: left.unit).displayName
                    < HealthMeasure.measure(for: right.type, storedUnit: right.unit).displayName
            }
    }

    func toggleComparison(_ type: String, limit: Int) {
        if let index = comparisonTypes.firstIndex(of: type) {
            comparisonTypes.remove(at: index)
        } else if comparisonTypes.count < limit {
            comparisonTypes.append(type)
        } else {
            // Replacing the oldest rather than refusing: the chip that was
            // tapped is the one the person wants to see.
            comparisonTypes.removeFirst()
            comparisonTypes.append(type)
        }
    }

    func loadComparison(range: ChartRange) async {
        guard let store else {
            comparison = []
            return
        }
        if archiveSpan == nil {
            archiveSpan = try? await store.archiveSpan()
        }
        chooseComparisonDefaults()
        guard !comparisonTypes.isEmpty else {
            comparison = []
            return
        }
        let plan = plan(for: range)
        var lines: [ComparisonSeries] = []
        for type in comparisonTypes {
            guard let series = try? await store.series(type: type, plan: plan),
                  let line = ComparisonSeries(series: series) else {
                continue
            }
            lines.append(line)
        }
        comparison = lines
    }

    /// Opens with two types already on the chart.
    ///
    /// A comparison screen that starts empty asks the question it exists to
    /// answer. Steps against resting heart rate is the pairing most people want
    /// first; if either is missing, the two largest types stand in, because
    /// whatever this archive holds most of is what it can best show.
    private func chooseComparisonDefaults() {
        guard comparisonTypes.isEmpty, !summaries.isEmpty else {
            return
        }
        let preferred = [
            "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierRestingHeartRate"
        ].filter { type in summaries.contains { $0.type == type } }

        if preferred.count == 2 {
            comparisonTypes = preferred
            return
        }
        comparisonTypes = comparableTypes
            .sorted { $0.recordCount > $1.recordCount }
            .prefix(2)
            .map(\.type)
    }

    func loadWorkouts() async {
        guard let store else { return }
        workouts = (try? await store.workouts(limit: 500)) ?? []
    }

    func route(forWorkout id: String) async -> WorkoutRoute? {
        guard let store else { return nil }
        return try? await store.route(forWorkout: id)
    }

    func heartRate(
        duringWorkout id: String
    ) async -> [(at: Date, beatsPerMinute: Double)] {
        guard let store else { return [] }
        return (try? await store.heartRate(duringWorkout: id)) ?? []
    }

    func loadElectrocardiograms() async {
        guard let store else { return }
        electrocardiograms = (try? await store.electrocardiograms()) ?? []
    }

    func loadWaveform(id: String) async {
        guard let store else { return }
        waveform = nil
        waveform = try? await store.voltages(forElectrocardiogram: id)
    }

    func loadMoodAndMedication() async {
        guard let store else { return }
        moods = (try? await store.moodEntries()) ?? []
        medications = (try? await store.medicationAdherence()) ?? []
    }

    func samples(type: String, limit: Int = 200) async -> [HealthRecord] {
        guard let store else { return [] }
        return (try? await store.samples(type: type, limit: limit)) ?? []
    }

    /// Writes every stored sample of a type to a file the user chose.
    func exportCSV(type: String, to url: URL) async throws {
        guard let store else { return }
        let records = try await store.samples(type: type, limit: .max)
        var text = "id,type,startDate,endDate,value,unit,source\n"
        for record in records {
            text += [
                Self.csvField(record.id),
                Self.csvField(record.type),
                Timestamps.text(from: record.startDate),
                Timestamps.text(from: record.endDate),
                record.value.map { String($0) } ?? "",
                Self.csvField(record.unit ?? ""),
                Self.csvField(record.sourceName ?? "")
            ].joined(separator: ",") + "\n"
        }
        try Data(text.utf8).write(to: url)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Records where this computer can actually be reached.
    ///
    /// Bonjour is not dependable — plenty of networks block mDNS, and a managed
    /// Mac may refuse to advertise on its real interface — so the address goes
    /// into the same private record as the token. The phone can then find this
    /// computer with no discovery at all.
    private func publishAddress(port: UInt16) {
        let hosts = LocalAddress.candidates()
        guard !token.isEmpty, !hosts.isEmpty else {
            return
        }
        let record = SharedReceiver(
            name: computerName.isEmpty ? "Mac" : "Hozz on \(computerName)",
            token: token,
            endpoints: hosts.map { "http://\($0):\(port)" }
        )
        Task { @MainActor in
            do {
                let group = SharedReceiverStore.resolvedAccessGroup()
                try SharedReceiverStore(accessGroup: group).publish(record)
                sharedWithOtherDevices = true
                // Addresses only — never the token.
                Self.log.info(
                    "Published \(record.endpoints.joined(separator: ", "), privacy: .public) to group \(group ?? "none", privacy: .public)"
                )
            } catch {
                sharedWithOtherDevices = false
                Self.log.error(
                    "Could not publish this Mac's address: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func apply(_ state: ReceiverState) {
        switch state {
        case .listening(let port):
            status = .ready(port: port)
            publishAddress(port: port)
        case .failed(let reason):
            status = .failed(reason)
        case .starting, .stopped:
            status = .starting
        }
    }

    /// The token is generated once and kept in the Keychain.
    ///
    /// The listener is reachable by anything else on the network — a guest
    /// phone, a smart TV, a housemate — so an unauthenticated receiver is not
    /// offered even as an option.
    nonisolated private static func resolveToken() throws -> String {
        let credentials = DestinationCredentials(
            service: "com.thatcube.Hozz.receiver"
        )
        if let existing = try credentials.secret(for: "receiver-token"),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try credentials.save(token, for: "receiver-token")
        return token
    }

    private static func localHostName() -> String {
        // The .local name follows the computer around every network it joins,
        // where an IP address does not.
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
