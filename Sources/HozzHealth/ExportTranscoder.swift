import Foundation

/// Reads an NDJSON spool back one line at a time.
///
/// The spool can be gigabytes, so lines are produced from a rolling buffer
/// rather than by loading the file.
struct NDJSONLineReader {
    private let handle: FileHandle
    private let bufferSize: Int
    private var buffer = Data()
    private var isAtEnd = false

    init(fileURL: URL, bufferSize: Int = 1 * 1_024 * 1_024) throws {
        handle = try FileHandle(forReadingFrom: fileURL)
        self.bufferSize = bufferSize
    }

    mutating func nextLine() throws -> Data? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<index)
                buffer = buffer.subdata(in: (index + 1)..<buffer.endIndex)
                if line.isEmpty {
                    continue
                }
                return line
            }
            guard !isAtEnd else {
                guard !buffer.isEmpty else {
                    return nil
                }
                let line = buffer
                buffer = Data()
                return line.isEmpty ? nil : line
            }

            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty {
                isAtEnd = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func close() {
        try? handle.close()
    }
}

/// Converts the NDJSON spool into the format the user asked for.
///
/// The spool is always NDJSON. That is deliberate: it is the format the
/// durability machinery is built and tested around, and a presentation choice
/// should not reach back into the part that has to survive a reboot. CSV and
/// JSON are produced by reading that stream once at the end.
enum ExportTranscoder {
    /// Record kinds that describe the run rather than the user's health data.
    private static let runRecordKinds: Set<String> = [
        "manifest",
        "resume",
        "typeSummary",
        "typeError",
        "completion",
        "sampleEncodingError",
        // Characteristics are the person, not a measurement, so they have no
        // per-type grid to sit in. They are kept whole in the export log and
        // also flattened into their own small file below.
        "characteristics"
    ]

    /// Writes one CSV entry per data type, plus a deletions file and the run's
    /// own records.
    ///
    /// Records for a type arrive contiguously, because a type is fully drained
    /// before the next one starts. A type that reappears anyway gets its own
    /// numbered file rather than silently overwriting the first.
    static func writeCSV(
        readingFrom sourceURL: URL,
        into archive: ZipStreamWriter
    ) throws {
        var reader = try NDJSONLineReader(fileURL: sourceURL)
        defer { reader.close() }

        var currentType: String?
        var currentKind: String?
        var seenTypes: [String: Int] = [:]
        var deletions: [(id: String, type: String)] = []
        var runRecords: [Data] = []
        var characteristicRows: [String] = []
        // One row per route, not per point, so this stays small however long
        // the rides were. The points themselves are streamed straight out.
        var routeRows: [RouteCSVRow] = []
        var ecgRows: [ECGCSVRow] = []
        var seriesCounts: [String: Int] = [:]

        func closeEntry() throws {
            if currentType != nil {
                try archive.endEntry()
                currentType = nil
                currentKind = nil
            }
        }

        while let line = try reader.nextLine() {
            guard
                let object = try JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
                let kind = object["kind"] as? String
            else {
                continue
            }

            if runRecordKinds.contains(kind) {
                runRecords.append(line)
                if kind == "characteristics" {
                    characteristicRows.append(
                        contentsOf: characteristicCSVRows(from: object)
                    )
                }
                continue
            }
            if kind == "deletion" {
                deletions.append(
                    (
                        id: object["id"] as? String ?? "",
                        type: object["type"] as? String ?? ""
                    )
                )
                continue
            }

            // A series type's three record kinds all share one type identifier,
            // so the per-type grouping below cannot hold them: a grid of route
            // headers and a grid of points are different shapes. They get their
            // own files, and the elements are written as they stream past
            // rather than gathered up first.
            if kind == "workoutRoute" {
                routeRows.append(routeCSVRow(from: object))
                continue
            }
            if kind == "electrocardiogram" {
                ecgRows.append(electrocardiogramCSVRow(from: object))
                continue
            }
            if let shape = seriesShape(endKind: kind) {
                if
                    let sample = object["sample"] as? String,
                    let count = object[shape.elementsKey] as? Int
                {
                    seriesCounts[sample] = count
                }
                continue
            }
            if let shape = seriesShape(elementKind: kind) {
                let entry = seriesElementEntry(for: shape)
                if currentType != entry {
                    try closeEntry()
                    try archive.beginEntry(name: entry)
                    try archive.write(
                        Data((seriesElementHeader(for: shape) + "\n").utf8)
                    )
                    currentType = entry
                    currentKind = kind
                }
                for row in seriesElementCSVRows(shape: shape, from: object) {
                    try archive.write(Data((row + "\n").utf8))
                }
                continue
            }

            guard let type = object["type"] as? String else {
                continue
            }

            if type != currentType {
                try closeEntry()
                let occurrence = (seenTypes[type] ?? 0) + 1
                seenTypes[type] = occurrence
                let name = fileName(for: type, occurrence: occurrence)
                try archive.beginEntry(name: name)
                try archive.write(Data((header(for: kind) + "\n").utf8))
                currentType = type
                currentKind = kind
            }

            try archive.write(
                Data((row(for: object, kind: currentKind ?? kind) + "\n").utf8)
            )
        }
        try closeEntry()

        if !deletions.isEmpty {
            try archive.beginEntry(name: "deletions.csv")
            try archive.write(Data("id,type\n".utf8))
            for deletion in deletions {
                try archive.write(
                    Data("\(escape(deletion.id)),\(escape(deletion.type))\n".utf8)
                )
            }
            try archive.endEntry()
        }

        if !routeRows.isEmpty {
            try archive.beginEntry(name: "WorkoutRoutes.csv")
            try archive.write(
                Data(
                    "id,startDate,endDate,workoutId,workoutActivityType,workoutState,locations,sourceName,device\n".utf8
                )
            )
            for route in routeRows {
                // The point count is only known once the route has been fully
                // written, so it is filled in here rather than guessed earlier.
                // A route with no count never reached its end marker, and is
                // left blank instead of being reported as zero.
                try archive.write(
                    Data(
                        (route.fields(locations: seriesCounts[route.id]) + "\n").utf8
                    )
                )
            }
            try archive.endEntry()
        }

        if !ecgRows.isEmpty {
            try archive.beginEntry(name: "Electrocardiograms.csv")
            try archive.write(
                Data(
                    "id,startDate,endDate,classification,symptomsStatus,averageHeartRate,samplingFrequency,reportedVoltages,exportedVoltages,sourceName,device\n".utf8
                )
            )
            for ecg in ecgRows {
                try archive.write(
                    Data((ecg.fields(exported: seriesCounts[ecg.id]) + "\n").utf8)
                )
            }
            try archive.endEntry()
        }

        if !characteristicRows.isEmpty {
            try archive.beginEntry(name: "characteristics.csv")
            try archive.write(
                Data("readAt,type,state,value,rawValue,coverage,reason\n".utf8)
            )
            for row in characteristicRows {
                try archive.write(Data((row + "\n").utf8))
            }
            try archive.endEntry()
        }

        try archive.beginEntry(name: "export-log.ndjson")
        for record in runRecords {
            try archive.write(record)
            try archive.write(Data([0x0A]))
        }
        try archive.endEntry()
    }

    /// Writes the whole export as one JSON array.
    static func writeJSON(
        readingFrom sourceURL: URL,
        into archive: ZipStreamWriter,
        entryName: String
    ) throws {
        var reader = try NDJSONLineReader(fileURL: sourceURL)
        defer { reader.close() }

        try archive.beginEntry(name: entryName)
        try archive.write(Data("[\n".utf8))

        var isFirst = true
        while let line = try reader.nextLine() {
            if !isFirst {
                try archive.write(Data(",\n".utf8))
            }
            try archive.write(line)
            isFirst = false
        }

        try archive.write(Data("\n]\n".utf8))
        try archive.endEntry()
    }

    // MARK: - Series types

    private static let seriesShapes: [SeriesShape] = [
        WorkoutRouteEncoding.shape,
        ElectrocardiogramEncoding.shape
    ]

    static func seriesShape(elementKind: String) -> SeriesShape? {
        seriesShapes.first { $0.elementKind == elementKind }
    }

    static func seriesShape(endKind: String) -> SeriesShape? {
        seriesShapes.first { $0.endKind == endKind }
    }

    static func seriesElementEntry(for shape: SeriesShape) -> String {
        switch shape.elementKind {
        case WorkoutRouteEncoding.shape.elementKind:
            "WorkoutRouteLocations.csv"
        default:
            "ElectrocardiogramVoltages.csv"
        }
    }

    static func seriesElementHeader(for shape: SeriesShape) -> String {
        switch shape.elementKind {
        case WorkoutRouteEncoding.shape.elementKind:
            "route,sequence,offset,timestamp,latitude,longitude,altitude,horizontalAccuracy,verticalAccuracy,course,speed,floor"
        default:
            "electrocardiogram,sequence,offset,timestamp,timeSinceStart,volts"
        }
    }

    /// One row per element, so a recording survives the grid instead of
    /// collapsing into a single unreadable cell.
    static func seriesElementCSVRows(
        shape: SeriesShape,
        from object: [String: Any]
    ) -> [String] {
        guard
            let elements = object[shape.elementsKey] as? [[String: Any]]
        else {
            return []
        }
        let sample = object["sample"] as? String ?? ""
        let sequence = number(object["sequence"])
        let offset = (object["offset"] as? Int) ?? 0
        let isRoute = shape.elementKind == WorkoutRouteEncoding.shape.elementKind

        return elements.enumerated().map { index, element in
            var fields = [sample, sequence, String(offset + index)]
            if isRoute {
                fields += [
                    element["timestamp"] as? String ?? "",
                    number(element["latitude"]),
                    number(element["longitude"]),
                    number(element["altitude"]),
                    number(element["horizontalAccuracy"]),
                    number(element["verticalAccuracy"]),
                    number(element["course"]),
                    number(element["speed"]),
                    number(element["floor"])
                ]
            } else {
                fields += [
                    object["startDate"] as? String ?? "",
                    number(element["timeSinceStart"]),
                    number(element["volts"])
                ]
            }
            return fields.map(escape).joined(separator: ",")
        }
    }

    /// A route's own row, held until its point count is known.
    struct RouteCSVRow {
        let id: String
        let startDate: String
        let endDate: String
        let workoutID: String
        let workoutActivityType: String
        let workoutState: String
        let sourceName: String
        let device: String

        func fields(locations: Int?) -> String {
            [
                id,
                startDate,
                endDate,
                workoutID,
                workoutActivityType,
                workoutState,
                locations.map(String.init) ?? "",
                sourceName,
                device
            ].map(escape).joined(separator: ",")
        }
    }

    static func routeCSVRow(from object: [String: Any]) -> RouteCSVRow {
        let workout = object["workout"] as? [String: Any] ?? [:]
        let source = object["source"] as? [String: Any] ?? [:]
        let device = object["device"] as? [String: Any]

        return RouteCSVRow(
            id: object["id"] as? String ?? "",
            startDate: object["startDate"] as? String ?? "",
            endDate: object["endDate"] as? String ?? "",
            workoutID: workout["id"] as? String ?? "",
            workoutActivityType: number(workout["activityType"]),
            workoutState: workout["state"] as? String ?? "",
            sourceName: source["name"] as? String ?? "",
            device: device?["name"] as? String ?? ""
        )
    }

    /// A recording's own row, held until its voltage count is known.
    struct ECGCSVRow {
        let id: String
        let startDate: String
        let endDate: String
        let classification: String
        let symptomsStatus: String
        let averageHeartRate: String
        let samplingFrequency: String
        let reportedVoltages: String
        let sourceName: String
        let device: String

        func fields(exported: Int?) -> String {
            [
                id,
                startDate,
                endDate,
                classification,
                symptomsStatus,
                averageHeartRate,
                samplingFrequency,
                reportedVoltages,
                // Health's own count and the number actually written are kept
                // side by side. If a recording was cut short, the two disagree
                // and say so rather than quietly matching.
                exported.map(String.init) ?? "",
                sourceName,
                device
            ].map(escape).joined(separator: ",")
        }
    }

    static func electrocardiogramCSVRow(from object: [String: Any]) -> ECGCSVRow {
        let classification = object["classification"] as? [String: Any] ?? [:]
        let symptoms = object["symptomsStatus"] as? [String: Any] ?? [:]
        let heartRate = object["averageHeartRate"] as? [String: Any]
        let frequency = object["samplingFrequency"] as? [String: Any]
        let source = object["source"] as? [String: Any] ?? [:]
        let device = object["device"] as? [String: Any]

        return ECGCSVRow(
            id: object["id"] as? String ?? "",
            startDate: object["startDate"] as? String ?? "",
            endDate: object["endDate"] as? String ?? "",
            classification: classification["name"] as? String ?? "",
            symptomsStatus: symptoms["name"] as? String ?? "",
            averageHeartRate: number(heartRate?["value"]),
            samplingFrequency: number(frequency?["value"]),
            reportedVoltages: number(object["numberOfVoltageMeasurements"]),
            sourceName: source["name"] as? String ?? "",
            device: device?["name"] as? String ?? ""
        )
    }

    // MARK: - CSV shaping

    /// Flattens one characteristics record into one row per characteristic.
    ///
    /// Every characteristic is emitted, including the ones with no value, so a
    /// spreadsheet shows "blood type: not set" rather than leaving the reader
    /// to guess whether Hozz looked.
    static func characteristicCSVRows(
        from object: [String: Any]
    ) -> [String] {
        guard
            let values = object["characteristics"] as? [String: Any]
        else {
            return []
        }
        let readAt = object["readAt"] as? String ?? ""

        return values.keys.sorted().compactMap { type in
            guard let entry = values[type] as? [String: Any] else {
                return nil
            }
            return [
                readAt,
                type,
                entry["state"] as? String ?? "",
                entry["value"] as? String ?? "",
                number(entry["rawValue"]),
                entry["coverage"] as? String ?? "",
                entry["reason"] as? String ?? ""
            ].map(escape).joined(separator: ",")
        }
    }

    static func fileName(for type: String, occurrence: Int) -> String {
        var name = type
        for prefix in [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKCorrelationTypeIdentifier",
            "HKWorkoutTypeIdentifier"
        ] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        if name.isEmpty {
            name = "Workout"
        }
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let suffix = occurrence > 1 ? "-\(occurrence)" : ""
        return "\(safe.isEmpty ? "Unknown" : safe)\(suffix).csv"
    }

    static func header(for kind: String) -> String {
        switch kind {
        case "quantity":
            "id,type,startDate,endDate,value,unit,sourceName,sourceBundleId,sourceVersion,device,metadata"
        case "category":
            "id,type,startDate,endDate,value,sourceName,sourceBundleId,sourceVersion,device,metadata"
        case "workout":
            "id,type,startDate,endDate,activityType,duration,sourceName,sourceBundleId,sourceVersion,device,metadata"
        default:
            "id,type,startDate,endDate,sourceName,sourceBundleId,sourceVersion,device,metadata"
        }
    }

    static func row(for object: [String: Any], kind: String) -> String {
        let source = object["source"] as? [String: Any] ?? [:]
        let device = object["device"] as? [String: Any]

        var fields: [String] = [
            object["id"] as? String ?? "",
            object["type"] as? String ?? "",
            object["startDate"] as? String ?? "",
            object["endDate"] as? String ?? ""
        ]

        switch kind {
        case "quantity":
            let quantity = object["quantity"] as? [String: Any] ?? [:]
            fields.append(number(quantity["value"]))
            fields.append(quantity["unit"] as? String ?? "")
        case "category":
            fields.append(number(object["value"]))
        case "workout":
            fields.append(number(object["activityType"]))
            fields.append(number(object["duration"]))
        default:
            break
        }

        fields.append(source["name"] as? String ?? "")
        fields.append(source["bundleIdentifier"] as? String ?? "")
        fields.append(source["version"] as? String ?? "")
        fields.append(device?["name"] as? String ?? "")
        fields.append(compactJSON(object["metadata"]))

        return fields.map(escape).joined(separator: ",")
    }

    private static func number(_ value: Any?) -> String {
        switch value {
        case let value as Int:
            String(value)
        case let value as Double:
            value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value))
                : String(value)
        case let value as NSNumber:
            value.stringValue
        default:
            ""
        }
    }

    private static func compactJSON(_ value: Any?) -> String {
        guard
            let value,
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: data, encoding: .utf8),
            text != "{}"
        else {
            return ""
        }
        return text
    }

    /// Quotes a field the way every spreadsheet expects.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
