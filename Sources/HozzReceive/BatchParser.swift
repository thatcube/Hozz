import Foundation
import HozzCore

/// One Health sample as it arrives from a phone.
///
/// This is deliberately lenient. The receiver is the far end of a wire the user
/// controls, and a record that cannot be fully understood is still worth
/// keeping — refusing it would silently drop data the user believes they
/// exported. Anything unrecognised is preserved in `raw` so nothing is lost.
public struct HealthRecord: Hashable, Sendable {
    public let id: String
    public let type: String
    public let kind: String?
    public let startDate: Date
    public let endDate: Date
    public let value: Double?
    public let unit: String?
    public let sourceName: String?
    public let raw: Data

    public init(
        id: String,
        type: String,
        kind: String? = nil,
        startDate: Date,
        endDate: Date,
        value: Double? = nil,
        unit: String? = nil,
        sourceName: String? = nil,
        raw: Data
    ) {
        self.id = id
        self.type = type
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.sourceName = sourceName
        self.raw = raw
    }
}

/// The shape the phone uses for characteristics, in one place.
///
/// The phone writes a single record holding every characteristic it read,
/// keyed by type. Reading it here rather than inline keeps the two halves of
/// the contract legible: if the encoder's shape changes, this is the file that
/// has to change with it.
enum HealthCharacteristicsShape {
    static let kind = "characteristics"

    static func characteristics(
        in object: [String: Any]
    ) -> [ReceivedCharacteristic] {
        let readAt = (object["readAt"] as? String)
            .flatMap(Timestamps.date(from:))

        // The combined shape: one record, every characteristic keyed by type.
        if let values = object["characteristics"] as? [String: Any] {
            return values.keys.sorted().compactMap { type in
                guard let entry = values[type] as? [String: Any] else {
                    return nil
                }
                return characteristic(
                    type: type,
                    object: entry,
                    readAt: readAt
                )
            }
        }

        // A single characteristic carrying its own type, so the receiver does
        // not depend on which of the two shapes the phone settles on.
        guard let type = object["type"] as? String else {
            return []
        }
        return [characteristic(type: type, object: object, readAt: readAt)]
    }

    private static func characteristic(
        type: String,
        object: [String: Any],
        readAt: Date?
    ) -> ReceivedCharacteristic {
        let raw = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()

        var value = object["value"] as? String
        if value == nil, let number = BatchParser.numeric(object["value"]) {
            value = String(number)
        }

        return ReceivedCharacteristic(
            type: type,
            state: object["state"] as? String,
            value: value,
            rawValue: BatchParser.numeric(object["rawValue"]).map { Int($0) },
            readAt: readAt,
            raw: raw
        )
    }
}

/// A sample the phone reports as removed from Health.
///
/// Deletions matter as much as additions: Health is the user's record of their
/// own body, and a receiver that only ever accumulates would keep showing data
/// they deliberately removed.
public struct HealthDeletion: Hashable, Sendable {
    public let id: String
    public let type: String?
    /// Set only for payload shapes that carry no per-sample identifier, where
    /// a deletion can only be matched by type and timestamp.
    public let startDate: Date?

    public init(id: String, type: String? = nil, startDate: Date? = nil) {
        self.id = id
        self.type = type
        self.startDate = startDate
    }
}

/// Everything one delivered batch contained.
/// One characteristic, as it arrived: a fact about the person rather than a
/// measurement of them.
///
/// The phone deliberately does not shape these like samples — a characteristic
/// has no identifier, no start date, and no source, and inventing them would
/// make a standing fact look like a measurement taken at export time. The
/// receiver therefore has to meet that shape rather than the other way round.
public struct ReceivedCharacteristic: Hashable, Sendable {
    public let type: String
    /// What Health actually said: `known`, `notSet`, `unavailable`, and so on.
    /// Kept because a blank value that means "declined to share" and one that
    /// means "never filled in" are different facts.
    public let state: String?
    public let value: String?
    public let rawValue: Int?
    public let readAt: Date?
    public let raw: Data

    public init(
        type: String,
        state: String?,
        value: String?,
        rawValue: Int?,
        readAt: Date?,
        raw: Data
    ) {
        self.type = type
        self.state = state
        self.value = value
        self.rawValue = rawValue
        self.readAt = readAt
        self.raw = raw
    }
}

/// A record the receiver could not interpret, kept whole anyway.
///
/// Dropping one of these is the failure this type exists to prevent. A phone
/// running a newer build can send a record shape this Mac has never heard of,
/// and the only two honest options are to store it uninterpreted or to refuse
/// the batch. Refusing wedges: the phone would resend the same bytes forever
/// and every later record behind it would be blocked. So it is stored, and the
/// count is surfaced where someone can see it.
public struct UnhandledRecord: Hashable, Sendable {
    /// A content hash, so the same record arriving twice is stored once.
    public let fingerprint: String
    public let kind: String?
    public let reason: String
    public let raw: Data

    public init(fingerprint: String, kind: String?, reason: String, raw: Data) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.reason = reason
        self.raw = raw
    }
}

/// One ECG reading, as it arrived.
public struct ReceivedElectrocardiogram: Hashable, Sendable {
    public let id: String
    public let startDate: Date
    public let endDate: Date?
    /// What the Watch concluded: `sinusRhythm`, `atrialFibrillation`, and so
    /// on. The single most useful field on the record, and the one that was
    /// invisible while these were stored as generic samples.
    public let classification: String?
    public let classificationRawValue: Int?
    public let symptomsStatus: String?
    public let averageHeartRate: Double?
    public let samplingHertz: Double?
    /// How many voltage measurements the Watch says this reading contains.
    public let expectedVoltages: Int?
    public let sourceName: String?
    public let raw: Data

    public init(
        id: String,
        startDate: Date,
        endDate: Date?,
        classification: String?,
        classificationRawValue: Int?,
        symptomsStatus: String?,
        averageHeartRate: Double?,
        samplingHertz: Double?,
        expectedVoltages: Int?,
        sourceName: String?,
        raw: Data
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.classification = classification
        self.classificationRawValue = classificationRawValue
        self.symptomsStatus = symptomsStatus
        self.averageHeartRate = averageHeartRate
        self.samplingHertz = samplingHertz
        self.expectedVoltages = expectedVoltages
        self.sourceName = sourceName
        self.raw = raw
    }
}

/// One page of a voltage series.
///
/// Pages are addressed by absolute offset and may arrive out of order, twice,
/// or not at all, so a page carries everything needed to place itself.
public struct ReceivedVoltagePage: Hashable, Sendable {
    public let sampleID: String
    public let sequence: Int
    public let offset: Int
    public let count: Int
    /// The points as delivered, kept verbatim.
    public let points: Data

    public init(
        sampleID: String,
        sequence: Int,
        offset: Int,
        count: Int,
        points: Data
    ) {
        self.sampleID = sampleID
        self.sequence = sequence
        self.offset = offset
        self.count = count
        self.points = points
    }
}

/// One hearing test.
public struct ReceivedAudiogram: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public let frequency: Double
        public let ear: String
        public let sensitivity: Double?
        public let unit: String?
        public let masked: Bool?
        /// A clamped reading is a bound rather than a measurement.
        public let clamped: Bool

        public init(
            frequency: Double,
            ear: String,
            sensitivity: Double?,
            unit: String?,
            masked: Bool?,
            clamped: Bool
        ) {
            self.frequency = frequency
            self.ear = ear
            self.sensitivity = sensitivity
            self.unit = unit
            self.masked = masked
            self.clamped = clamped
        }
    }

    public let id: String
    public let startDate: Date
    public let endDate: Date?
    public let sourceName: String?
    public let points: [Point]
    public let raw: Data

    public init(
        id: String,
        startDate: Date,
        endDate: Date?,
        sourceName: String?,
        points: [Point],
        raw: Data
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.sourceName = sourceName
        self.points = points
        self.raw = raw
    }
}

public struct ParsedBatch: Hashable, Sendable {
    public let records: [HealthRecord]
    public let deletions: [HealthDeletion]
    public let characteristics: [ReceivedCharacteristic]
    public let electrocardiograms: [ReceivedElectrocardiogram]
    public let voltagePages: [ReceivedVoltagePage]
    public let audiograms: [ReceivedAudiogram]
    public let moodEntries: [ReceivedMoodEntry]
    public let medicationDoses: [ReceivedMedicationDose]
    /// Records the receiver could not interpret. They are still stored, so this
    /// is a list of things to teach it about rather than a list of losses.
    public let unhandled: [UnhandledRecord]
    /// Lines that could not be parsed at all, kept only as a count so nothing
    /// about their contents is logged.
    public let unreadableCount: Int

    public var isEmpty: Bool {
        records.isEmpty
            && deletions.isEmpty
            && characteristics.isEmpty
            && electrocardiograms.isEmpty
            && voltagePages.isEmpty
            && audiograms.isEmpty
            && moodEntries.isEmpty
            && medicationDoses.isEmpty
            && unhandled.isEmpty
    }

    public init(
        records: [HealthRecord],
        deletions: [HealthDeletion],
        characteristics: [ReceivedCharacteristic] = [],
        electrocardiograms: [ReceivedElectrocardiogram] = [],
        voltagePages: [ReceivedVoltagePage] = [],
        audiograms: [ReceivedAudiogram] = [],
        moodEntries: [ReceivedMoodEntry] = [],
        medicationDoses: [ReceivedMedicationDose] = [],
        unhandled: [UnhandledRecord] = [],
        unreadableCount: Int
    ) {
        self.records = records
        self.deletions = deletions
        self.characteristics = characteristics
        self.electrocardiograms = electrocardiograms
        self.voltagePages = voltagePages
        self.audiograms = audiograms
        self.moodEntries = moodEntries
        self.medicationDoses = medicationDoses
        self.unhandled = unhandled
        self.unreadableCount = unreadableCount
    }
}

public enum BatchParseError: Error, LocalizedError, Sendable {
    case connectionTest

    public var errorDescription: String? {
        switch self {
        case .connectionTest:
            "This was a connection test, not a batch of samples."
        }
    }
}

/// Turns a delivered payload into records, whatever shape it arrived in.
///
/// Hozz can deliver NDJSON, a JSON array, CSV, or a flattened metrics envelope,
/// and the receiver has no reliable way to be told which — a user can point any
/// destination at it. So the shape is detected rather than configured, because
/// a mismatch that silently stores nothing is the worst possible outcome.
public enum BatchParser {
    /// How much this parser understands, bumped whenever it learns a new
    /// record shape.
    ///
    /// Quarantined records remember the version that failed to read them, so
    /// the promotion pass can reconsider exactly the rows a newer parser might
    /// now handle and skip the rest. Without it, teaching the parser anything
    /// would mean rescanning every quarantined record on every launch forever.
    ///
    /// Bump this in the same commit that teaches the parser a shape.
    /// - 1: samples, deletions.
    /// - 2: characteristics, and quarantine instead of dropping.
    /// - 3: ECG readings, their voltage pages, and audiograms.
    /// - 4: State of Mind valence, and medication doses.
    public static let parserVersion = 4

    public static func parse(_ payload: Data) throws -> ParsedBatch {
        let text = String(decoding: payload, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 0)
        }

        // A connection test is a real, valid request that carries no samples.
        // Treating it as an unparseable batch would report a working setup as
        // broken at exactly the moment the user is checking it.
        if trimmed.contains("hozzConnectionTest") {
            throw BatchParseError.connectionTest
        }

        if trimmed.hasPrefix("[") {
            return parseJSONArray(trimmed)
        }
        if trimmed.hasPrefix("{"), trimmed.contains("\"metrics\"") {
            return parseMetricsEnvelope(trimmed)
        }
        if trimmed.hasPrefix("{") {
            return parseLines(trimmed)
        }
        if looksLikeCSV(trimmed) {
            return parseCSV(trimmed)
        }
        return parseLines(trimmed)
    }

    private static func looksLikeCSV(_ text: String) -> Bool {
        guard let first = text.split(separator: "\n", maxSplits: 1).first else {
            return false
        }
        return first.contains("startDate") && first.contains(",")
    }

    private static func parseJSONArray(_ text: String) -> ParsedBatch {
        guard
            let data = text.data(using: .utf8),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 1)
        }
        return collect(items)
    }

    private static func parseLines(_ text: String) -> ParsedBatch {
        var objects: [[String: Any]] = []
        var quarantined: [UnhandledRecord] = []
        var unreadable = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else {
                continue
            }
            guard
                let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // Not JSON at all, so there is nothing to interpret — but the
                // phone has already advanced its cursor past it, and dropping
                // it would be the same permanent loss by a different route.
                // The bytes are kept verbatim instead.
                unreadable += 1
                let raw = candidate.data(using: .utf8) ?? Data()
                quarantined.append(
                    UnhandledRecord(
                        fingerprint: fingerprint(of: raw),
                        kind: nil,
                        reason: "This line was not readable as JSON.",
                        raw: raw
                    )
                )
                continue
            }
            objects.append(object)
        }
        let batch = collect(objects)
        return ParsedBatch(
            records: batch.records,
            deletions: batch.deletions,
            characteristics: batch.characteristics,
            electrocardiograms: batch.electrocardiograms,
            voltagePages: batch.voltagePages,
            audiograms: batch.audiograms,
            moodEntries: batch.moodEntries,
            medicationDoses: batch.medicationDoses,
            unhandled: batch.unhandled + quarantined,
            unreadableCount: batch.unreadableCount + unreadable
        )
    }

    private static func collect(_ objects: [[String: Any]]) -> ParsedBatch {
        var records: [HealthRecord] = []
        var deletions: [HealthDeletion] = []
        var characteristics: [ReceivedCharacteristic] = []
        var electrocardiograms: [ReceivedElectrocardiogram] = []
        var voltagePages: [ReceivedVoltagePage] = []
        var audiograms: [ReceivedAudiogram] = []
        var moodEntries: [ReceivedMoodEntry] = []
        var medicationDoses: [ReceivedMedicationDose] = []
        var unhandled: [UnhandledRecord] = []
        var unreadable = 0

        for object in objects {
            // Hozz's own encoder marks a removed sample with `kind: "deletion"`
            // and no dates; other producers use a `deleted` flag. Missing the
            // first meant a deletion was counted as unreadable, answered 200,
            // and never resent — so a sample the user deleted from Health stayed
            // on the receiver permanently and kept being served as live data.
            let isDeletion = (object["deleted"] as? Bool == true)
                || (object["kind"] as? String == "deletion")
            if isDeletion, let id = object["id"] as? String {
                deletions.append(
                    HealthDeletion(id: id, type: object["type"] as? String)
                )
                continue
            }

            let kind = object["kind"] as? String

            // Characteristics are the same failure in a new shape. They carry
            // no id, no type, and no startDate — deliberately, because a blood
            // type is not a measurement taken at export time — so the sample
            // parser rejected every one of them, the batch still answered 200,
            // and the phone never sent them again.
            if kind == HealthCharacteristicsShape.kind || kind == "characteristic" {
                let parsed = HealthCharacteristicsShape.characteristics(in: object)
                if parsed.isEmpty {
                    unhandled.append(
                        unhandledRecord(
                            object,
                            kind: kind,
                            reason: "A characteristics record with nothing in it."
                        )
                    )
                } else {
                    characteristics.append(contentsOf: parsed)
                }
                continue
            }

            // ECG readings, their voltage pages, and hearing tests all parse
            // as generic samples — they carry ids and dates — which is why
            // they were never lost. But a generic sample has one value, and
            // these have none: an ECG's answer is its classification, a
            // hearing test's is a curve. Stored generically, "how many ECGs do
            // I have" counted the voltage pages as readings and the
            // classification was invisible. So they are read properly here,
            // before the generic path can claim them.
            switch kind {
            case MoodAndMedicationShape.moodKind:
                // Deliberately not `continue`: a mood entry is one reading
                // with one number, so it also becomes an ordinary sample row
                // and stays chartable and comparable through every tool that
                // already exists.
                if let mood = MoodAndMedicationShape.mood(in: object) {
                    moodEntries.append(mood)
                }
            case MoodAndMedicationShape.doseKind:
                // A dose has no number to chart — its answer is a status — so
                // unlike mood it does not also become a sample row, where it
                // would sit with an empty value and hide the only thing that
                // matters about it.
                if let dose = MoodAndMedicationShape.dose(in: object) {
                    medicationDoses.append(dose)
                    continue
                }
            case ElectrocardiogramShape.headerKind:
                if let ecg = ElectrocardiogramShape.reading(in: object) {
                    electrocardiograms.append(ecg)
                    continue
                }
            case ElectrocardiogramShape.elementKind:
                if let page = ElectrocardiogramShape.page(in: object) {
                    voltagePages.append(page)
                    continue
                }
            case ElectrocardiogramShape.endKind:
                // The end marker carries no data of its own; the header
                // already says how many measurements to expect.
                continue
            case AudiogramShape.kind:
                if let audiogram = AudiogramShape.audiogram(in: object) {
                    audiograms.append(audiogram)
                    continue
                }
            default:
                break
            }

            if let record = record(from: object) {
                records.append(record)
                continue
            }

            // Anything else is kept rather than dropped. This is the branch
            // that used to lose data, and it is deliberately the last one: a
            // record shape added by a newer phone lands here and survives
            // uninterpreted until this Mac learns about it.
            unhandled.append(
                unhandledRecord(
                    object,
                    kind: kind,
                    reason: kind.map { "No place yet for a \($0) record." }
                        ?? "A record with no kind, id, type, or start date."
                )
            )
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            characteristics: characteristics,
            electrocardiograms: electrocardiograms,
            voltagePages: voltagePages,
            audiograms: audiograms,
            moodEntries: moodEntries,
            medicationDoses: medicationDoses,
            unhandled: unhandled,
            unreadableCount: unreadable
        )
    }

    private static func unhandledRecord(
        _ object: [String: Any],
        kind: String?,
        reason: String
    ) -> UnhandledRecord {
        let raw = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return UnhandledRecord(
            fingerprint: fingerprint(of: raw),
            kind: kind,
            reason: reason,
            raw: raw
        )
    }

    /// A stable content hash, so a retried delivery stores one row rather than
    /// a second copy of the same unhandled record.
    static func fingerprint(of data: Data) -> String {
        // FNV-1a over the canonical bytes. This is a de-duplication key, not a
        // security boundary, so a short non-cryptographic hash is the right
        // tool and avoids pulling in CryptoKit for it.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    static func record(from object: [String: Any]) -> HealthRecord? {
        guard
            let id = object["id"] as? String,
            let type = object["type"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText)
        else {
            return nil
        }
        let end = (object["endDate"] as? String)
            .flatMap(Timestamps.date(from:)) ?? start

        var value: Double?
        var unit: String?
        if let quantity = object["quantity"] as? [String: Any] {
            value = numeric(quantity["value"])
            unit = quantity["unit"] as? String
        } else {
            value = numeric(object["value"])
            unit = object["unit"] as? String
        }
        // A State of Mind entry's number is its valence, and it is called
        // that. Without this the row carries no value at all, so mood cannot
        // be charted, trended, or compared against anything — and every tool
        // that filters on a value reports the entries as absent while they sit
        // in the table.
        if value == nil, let valence = numeric(object["valence"]) {
            value = valence
            unit = unit ?? "valence"
        }

        var sourceName: String?
        if let source = object["source"] as? [String: Any] {
            sourceName = source["name"] as? String
        } else {
            sourceName = object["sourceName"] as? String
        }

        let raw = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()

        return HealthRecord(
            id: id,
            type: type,
            kind: object["kind"] as? String,
            startDate: start,
            endDate: end,
            value: value,
            unit: unit,
            sourceName: sourceName,
            raw: raw
        )
    }

    /// The metrics shape carries no per-sample identifier, so one is derived
    /// from the type and timestamp. That is what makes re-delivering the same
    /// metric update a row rather than duplicate it.
    private static func parseMetricsEnvelope(_ text: String) -> ParsedBatch {
        guard
            let data = text.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = envelope["data"] as? [String: Any]
        else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 1)
        }

        var records: [HealthRecord] = []
        var unreadable = 0
        for metric in payload["metrics"] as? [[String: Any]] ?? [] {
            let name = metric["name"] as? String ?? "unknown"
            let units = metric["units"] as? String
            for point in metric["data"] as? [[String: Any]] ?? [] {
                guard
                    let dateText = point["date"] as? String,
                    let date = Timestamps.date(from: dateText)
                else {
                    unreadable += 1
                    continue
                }
                let end = (point["endDate"] as? String)
                    .flatMap(Timestamps.date(from:)) ?? date
                let identifier = "\(name):\(dateText)"
                var object: [String: Any] = [
                    "id": identifier,
                    "type": name,
                    "startDate": dateText
                ]
                if let quantity = numeric(point["qty"]) {
                    object["value"] = quantity
                }
                if let units {
                    object["unit"] = units
                }
                records.append(
                    HealthRecord(
                        id: identifier,
                        type: name,
                        kind: "quantity",
                        startDate: date,
                        endDate: end,
                        value: numeric(point["qty"]),
                        unit: units,
                        sourceName: point["source"] as? String,
                        raw: (try? JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys]
                        )) ?? Data()
                    )
                )
            }
        }

        // Workouts travel in their own key, not in `metrics`. Missing them meant
        // every workout sent in this format was discarded, counted as nothing,
        // and answered 200 — so it was never sent again.
        for workout in payload["workouts"] as? [[String: Any]] ?? [] {
            guard
                let identifier = workout["id"] as? String,
                let startText = workout["start"] as? String,
                let start = Timestamps.date(from: startText)
            else {
                unreadable += 1
                continue
            }
            let end = (workout["end"] as? String)
                .flatMap(Timestamps.date(from:)) ?? start
            let name = workout["name"] as? String ?? "Workout"
            let object: [String: Any] = [
                "id": identifier,
                "type": name,
                "kind": "workout",
                "startDate": startText,
                "endDate": workout["end"] as? String ?? startText
            ]
            records.append(
                HealthRecord(
                    id: identifier,
                    type: name,
                    kind: "workout",
                    startDate: start,
                    endDate: end,
                    value: nil,
                    unit: nil,
                    sourceName: workout["source"] as? String,
                    raw: (try? JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    )) ?? Data()
                )
            )
        }

        var deletions: [HealthDeletion] = []
        for deletion in payload["deletions"] as? [[String: Any]] ?? [] {
            guard
                let name = (deletion["name"] as? String) ?? (deletion["type"] as? String),
                let dateText = deletion["date"] as? String,
                let date = Timestamps.date(from: dateText)
            else {
                continue
            }
            deletions.append(
                HealthDeletion(id: "\(name):\(dateText)", type: name, startDate: date)
            )
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            unreadableCount: unreadable
        )
    }

    private static func parseCSV(_ text: String) -> ParsedBatch {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 0)
        }
        let header = CSV.fields(in: String(lines.removeFirst()))

        var records: [HealthRecord] = []
        var deletions: [HealthDeletion] = []
        var unreadable = 0

        for line in lines {
            let fields = CSV.fields(in: String(line))
            guard fields.count == header.count else {
                unreadable += 1
                continue
            }
            var object: [String: Any] = [:]
            for (key, field) in zip(header, fields) where !field.isEmpty {
                object[key] = field
            }
            if let deleted = object["deleted"] as? String,
               deleted == "true" || deleted == "1",
               let id = object["id"] as? String {
                deletions.append(
                    HealthDeletion(id: id, type: object["type"] as? String)
                )
                continue
            }
            // CSV carries every field as text, so the numeric column is
            // converted before the shared decoder sees it.
            if let raw = object["value"] as? String, let number = Double(raw) {
                object["value"] = number
            }
            guard let record = record(from: object) else {
                unreadable += 1
                continue
            }
            records.append(record)
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            unreadableCount: unreadable
        )
    }

    static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }
}

/// Parses and writes the timestamp formats Hozz emits.
///
/// `ISO8601FormatStyle` is a value type, so unlike a shared `DateFormatter` it
/// carries no mutable state across threads — which matters here because
/// batches are parsed off the network on whichever queue delivered them.
public enum Timestamps {
    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let whole = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    public static func date(from text: String) -> Date? {
        // Both are tried because Hozz writes fractional seconds but other
        // producers pointed at the same receiver frequently do not.
        if let parsed = try? fractional.parse(text) {
            return parsed
        }
        return try? whole.parse(text)
    }

    public static func text(from date: Date) -> String {
        fractional.format(date)
    }
}

/// Minimal RFC 4180 field splitting, enough for the CSV Hozz writes.
enum CSV {
    static func fields(in line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if isQuoted {
                if character == "\"" {
                    // A doubled quote inside a quoted field is a literal quote.
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else if next == "," {
                            fields.append(current)
                            current = ""
                            isQuoted = false
                        } else {
                            isQuoted = false
                            current.append(next)
                        }
                    } else {
                        isQuoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"", current.isEmpty {
                isQuoted = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else if character != "\r" {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

/// The shape the phone uses for an ECG, in one place.
///
/// Kept beside the characteristics reader for the same reason: this is one
/// half of a contract whose other half lives in the phone's encoder, and a
/// change there has to be answerable by a change here.
enum ElectrocardiogramShape {
    static let headerKind = "electrocardiogram"
    static let elementKind = "electrocardiogramVoltages"
    static let endKind = "electrocardiogramEnd"

    static func reading(in object: [String: Any]) -> ReceivedElectrocardiogram? {
        guard
            let id = object["id"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText)
        else {
            return nil
        }

        let classification = object["classification"] as? [String: Any]
        let symptoms = object["symptomsStatus"] as? [String: Any]

        return ReceivedElectrocardiogram(
            id: id,
            startDate: start,
            endDate: (object["endDate"] as? String).flatMap(Timestamps.date(from:)),
            classification: classification?["name"] as? String,
            classificationRawValue: BatchParser.numeric(classification?["rawValue"])
                .map { Int($0) },
            symptomsStatus: symptoms?["name"] as? String,
            averageHeartRate: quantityValue(object["averageHeartRate"]),
            samplingHertz: quantityValue(object["samplingFrequency"]),
            expectedVoltages: BatchParser.numeric(object["numberOfVoltageMeasurements"])
                .map { Int($0) },
            sourceName: (object["source"] as? [String: Any])?["name"] as? String,
            raw: canonical(object)
        )
    }

    static func page(in object: [String: Any]) -> ReceivedVoltagePage? {
        guard
            let sample = object["sample"] as? String,
            let sequence = BatchParser.numeric(object["sequence"]).map({ Int($0) }),
            let offset = BatchParser.numeric(object["offset"]).map({ Int($0) }),
            let points = object["voltages"] as? [[String: Any]]
        else {
            return nil
        }
        // `count` is what the page claims; the array is what it holds. The
        // array wins, because it is the thing that will actually be read back.
        return ReceivedVoltagePage(
            sampleID: sample,
            sequence: sequence,
            offset: offset,
            count: points.count,
            points: (try? JSONSerialization.data(
                withJSONObject: points,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )) ?? Data()
        )
    }

    private static func quantityValue(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else {
            return BatchParser.numeric(value)
        }
        return BatchParser.numeric(object["value"])
    }

    static func canonical(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }
}

/// The shape the phone uses for a hearing test.
enum AudiogramShape {
    static let kind = "audiogram"

    static func audiogram(in object: [String: Any]) -> ReceivedAudiogram? {
        guard
            let id = object["id"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText)
        else {
            return nil
        }

        var points: [ReceivedAudiogram.Point] = []
        for entry in object["sensitivityPoints"] as? [[String: Any]] ?? [] {
            guard
                let frequency = quantity(entry["frequency"])
            else {
                continue
            }
            for ear in entry["ears"] as? [[String: Any]] ?? [] {
                points.append(
                    ReceivedAudiogram.Point(
                        frequency: frequency,
                        ear: ear["ear"] as? String ?? "unknown",
                        sensitivity: quantity(ear["sensitivity"]),
                        unit: (ear["sensitivity"] as? [String: Any])?["unit"] as? String,
                        masked: ear["masked"] as? Bool,
                        clamped: ear["clampingRange"] != nil
                    )
                )
            }
        }

        return ReceivedAudiogram(
            id: id,
            startDate: start,
            endDate: (object["endDate"] as? String).flatMap(Timestamps.date(from:)),
            sourceName: (object["source"] as? [String: Any])?["name"] as? String,
            points: points,
            raw: ElectrocardiogramShape.canonical(object)
        )
    }

    private static func quantity(_ value: Any?) -> Double? {
        guard let object = value as? [String: Any] else {
            return BatchParser.numeric(value)
        }
        return BatchParser.numeric(object["value"])
    }
}

/// One State of Mind entry: a mood the person logged.
///
/// Kept alongside its sample row rather than instead of it. Unlike an ECG,
/// this genuinely is one reading with one number — the valence — so it belongs
/// in `sample` where every existing tool can chart it, and this carries the
/// parts a single column cannot: what kind of entry it was, how Health
/// classified the feeling, and what the person attributed it to.
public struct ReceivedMoodEntry: Hashable, Sendable {
    public let id: String
    public let startDate: Date
    public let endDate: Date?
    /// -1 (very unpleasant) through +1 (very pleasant).
    public let valence: Double
    public let classification: String?
    /// `momentaryEmotion` or `dailyMood`. Averaging the two together would mix
    /// a snapshot with a summary of a whole day.
    public let kindOfEntry: String?
    public let labels: [String]
    public let associations: [String]
    public let sourceName: String?
    public let raw: Data

    public init(
        id: String,
        startDate: Date,
        endDate: Date?,
        valence: Double,
        classification: String?,
        kindOfEntry: String?,
        labels: [String],
        associations: [String],
        sourceName: String?,
        raw: Data
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.valence = valence
        self.classification = classification
        self.kindOfEntry = kindOfEntry
        self.labels = labels
        self.associations = associations
        self.sourceName = sourceName
        self.raw = raw
    }
}

/// One medication dose event.
///
/// The status is the whole record. Only `taken` means the medicine was
/// actually taken; `skipped`, `snoozed` and `notAnswered` are three different
/// ways of not taking it, and flattening them answers "did I take my
/// medication?" wrongly — which is worse than not answering at all.
public struct ReceivedMedicationDose: Hashable, Sendable {
    public let id: String
    public let startDate: Date
    public let logStatus: String
    public let scheduleType: String?
    public let doseQuantity: Double?
    public let scheduledDoseQuantity: Double?
    public let unit: String?
    public let medicationName: String?
    public let medicationForm: String?
    public let sourceName: String?
    public let raw: Data

    /// The one status that means the dose was taken.
    public var wasTaken: Bool {
        logStatus == "taken"
    }

    public init(
        id: String,
        startDate: Date,
        logStatus: String,
        scheduleType: String?,
        doseQuantity: Double?,
        scheduledDoseQuantity: Double?,
        unit: String?,
        medicationName: String?,
        medicationForm: String?,
        sourceName: String?,
        raw: Data
    ) {
        self.id = id
        self.startDate = startDate
        self.logStatus = logStatus
        self.scheduleType = scheduleType
        self.doseQuantity = doseQuantity
        self.scheduledDoseQuantity = scheduledDoseQuantity
        self.unit = unit
        self.medicationName = medicationName
        self.medicationForm = medicationForm
        self.sourceName = sourceName
        self.raw = raw
    }
}

/// The shapes the phone uses for mood and medication.
enum MoodAndMedicationShape {
    static let moodKind = "stateOfMind"
    static let doseKind = "medicationDose"

    static func mood(in object: [String: Any]) -> ReceivedMoodEntry? {
        guard
            let id = object["id"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText),
            let valence = BatchParser.numeric(object["valence"])
        else {
            return nil
        }
        return ReceivedMoodEntry(
            id: id,
            startDate: start,
            endDate: (object["endDate"] as? String).flatMap(Timestamps.date(from:)),
            valence: valence,
            classification: (object["valenceClassification"] as? [String: Any])?["name"] as? String,
            kindOfEntry: (object["kindOfEntry"] as? [String: Any])?["name"] as? String,
            labels: names(in: object["labels"]),
            associations: names(in: object["associations"]),
            sourceName: (object["source"] as? [String: Any])?["name"] as? String,
            raw: ElectrocardiogramShape.canonical(object)
        )
    }

    static func dose(in object: [String: Any]) -> ReceivedMedicationDose? {
        guard
            let id = object["id"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText)
        else {
            return nil
        }
        let medication = object["medication"] as? [String: Any] ?? [:]
        return ReceivedMedicationDose(
            id: id,
            startDate: start,
            // An unnamed status is recorded as unrecorded rather than guessed
            // at, because every guess here is a claim about whether someone
            // took their medicine.
            logStatus: (object["logStatus"] as? [String: Any])?["name"] as? String
                ?? "unrecorded",
            scheduleType: (object["scheduleType"] as? [String: Any])?["name"] as? String,
            doseQuantity: BatchParser.numeric(object["doseQuantity"]),
            scheduledDoseQuantity: BatchParser.numeric(object["scheduledDoseQuantity"]),
            unit: object["unit"] as? String,
            medicationName: medication["displayText"] as? String
                ?? medication["nickname"] as? String,
            medicationForm: (medication["generalForm"] as? [String: Any])?["name"] as? String,
            sourceName: (object["source"] as? [String: Any])?["name"] as? String,
            raw: ElectrocardiogramShape.canonical(object)
        )
    }

    private static func names(in value: Any?) -> [String] {
        (value as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }
}
