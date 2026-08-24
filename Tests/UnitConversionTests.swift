import Foundation
@testable import HozzDeliver
import HozzStore
import XCTest

/// Whether a converted number is the right number, and whether it arrives
/// wearing the right name.
///
/// Every expected value here is worked out from a definition or from a fact
/// that exists outside this repository — a marathon is 42.195 km and 26.219
/// miles, water freezes at 0 °C and 32 °F, a pound is 0.45359237 kg — and never
/// by running the conversion and writing down what came out. A test that
/// computed its own expectation from the code under test could only prove the
/// copy agreed with itself.
///
/// This is health data. A weight that is wrong by a factor of 2.2 is a
/// prescription that is wrong by a factor of 2.2.
final class UnitConversionTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - Known distances

    /// The marathon, which is 42.195 kilometres by definition and 26.219 miles
    /// to the three decimal places everybody quotes.
    func testAMarathonIsTheDistanceEverybodyKnowsItIs() throws {
        let miles = try XCTUnwrap(HealthUnit.convert(42.195, from: "km", to: "mi"))
        XCTAssertEqual(miles, 26.219, accuracy: 0.001)

        let back = try XCTUnwrap(HealthUnit.convert(miles, from: "mi", to: "km"))
        XCTAssertEqual(back, 42.195, accuracy: 0.000_001)

        let metres = try XCTUnwrap(HealthUnit.convert(42.195, from: "km", to: "m"))
        XCTAssertEqual(metres, 42_195, accuracy: 0.000_001)
    }

    /// The international yard is exactly 0.9144 m, and foot, inch and mile all
    /// follow from it. These are definitions, not measurements.
    func testTheImperialLengthsAreTheirDefinedValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "in", to: "m")),
            0.0254,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "ft", to: "m")),
            0.3048,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "mi", to: "m")),
            1_609.344,
            accuracy: 1e-9
        )
        // Twelve inches to the foot, 5,280 feet to the mile.
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "ft", to: "in")),
            12,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "mi", to: "ft")),
            5_280,
            accuracy: 1e-6
        )
    }

    /// Six feet, which is 182.88 cm exactly.
    func testASixFootPersonIsTheRightHeightInCentimetres() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(72, from: "in", to: "cm")),
            182.88,
            accuracy: 1e-9
        )
    }

    // MARK: - Known weights

    /// A pound is exactly 0.45359237 kg, so a stone is exactly 6.35029318 kg
    /// and 70 kg is 154.32 lb.
    func testTheWeightsAreTheirDefinedValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "lb", to: "kg")),
            0.453_592_37,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "st", to: "kg")),
            6.350_293_18,
            accuracy: 1e-11
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "st", to: "lb")),
            14,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(70, from: "kg", to: "lb")),
            154.3236,
            accuracy: 0.0001
        )
    }

    func testAWeightSurvivesTheRoundTrip() throws {
        let pounds = try XCTUnwrap(HealthUnit.convert(82.6, from: "kg", to: "lb"))
        let back = try XCTUnwrap(HealthUnit.convert(pounds, from: "lb", to: "kg"))
        XCTAssertEqual(back, 82.6, accuracy: 1e-9)
    }

    // MARK: - Temperature, which is not a scale factor

    /// The mistake this guards against turns a fever into hypothermia. 38 °C is
    /// 100.4 °F; multiplying by a factor would give 38 °F.
    func testTemperatureUsesTheOffsetAndNotAFactor() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(0, from: "degC", to: "degF")),
            32,
            accuracy: 1e-9,
            "Water freezes at 32 °F, not 0 °F."
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(100, from: "degC", to: "degF")),
            212,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(38, from: "degC", to: "degF")),
            100.4,
            accuracy: 1e-9,
            "A fever, not a room temperature."
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(98.6, from: "degF", to: "degC")),
            37,
            accuracy: 1e-9
        )
        // The one temperature that is the same number in both.
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(-40, from: "degC", to: "degF")),
            -40,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(0, from: "degC", to: "K")),
            273.15,
            accuracy: 1e-9
        )
    }

    // MARK: - Energy, pressure, speed, volume

    /// HealthKit's kilocalorie is the thermochemical one: exactly 4184 joules.
    func testEnergyUsesTheThermochemicalCalorie() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "kcal", to: "kJ")),
            4.184,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(2_000, from: "kcal", to: "kJ")),
            8_368,
            accuracy: 1e-9,
            "A day's intake, in the number a European food label would print."
        )
    }

    /// HealthKit spells the large calorie `Cal` and the small one `cal`, and
    /// they differ by a factor of a thousand. Filing one as the other would
    /// report a day's food as two calories, or a biscuit as a week's worth.
    func testTheLargeAndSmallCalorieAreNotConfused() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "Cal", to: "J")),
            4_184,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "cal", to: "J")),
            4.184,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "Cal", to: "cal")),
            1_000,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "Cal", to: "kcal")),
            1,
            accuracy: 1e-12,
            "They are two spellings of the same unit."
        )
    }

    /// An inch of mercury is exactly 25.4 mmHg, which follows from the exact
    /// inch and the defined millimetre of mercury.
    func testInchesOfMercuryFollowFromMillimetres() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "inHg", to: "mmHg")),
            25.4,
            accuracy: 1e-9
        )
    }

    /// A millimetre of mercury is exactly 133.322387415 Pa, so a blood pressure
    /// of 120 mmHg is 15.999 kPa.
    func testBloodPressureConvertsToTheRightPressure() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(120, from: "mmHg", to: "kPa")),
            15.998_686_49,
            accuracy: 1e-7
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(80, from: "mmHg", to: "kPa")),
            10.665_790_99,
            accuracy: 1e-7
        )
    }

    /// A mile per hour is exactly 0.44704 m/s, and 100 km/h is 62.137 mph.
    func testSpeedsConvertToTheirDefinedValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "mi/hr", to: "m/s")),
            0.44704,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(100, from: "km/hr", to: "mi/hr")),
            62.137_119,
            accuracy: 1e-6
        )
    }

    /// A US fluid ounce is a 128th of a US gallon, and that gallon is exactly
    /// 3.785411784 L — so a fluid ounce is 29.5735295625 mL.
    func testVolumesConvertToTheirDefinedValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(1, from: "fl_oz_us", to: "mL")),
            29.573_529_562_5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            try XCTUnwrap(HealthUnit.convert(2, from: "L", to: "fl_oz_us")),
            67.628,
            accuracy: 0.001,
            "Two litres of water, in the number a US bottle would print."
        )
    }

    // MARK: - Refusing rather than guessing

    /// Returning the original number would leave a caller unable to tell a
    /// converted value from an unconverted one, and it would go on to label
    /// kilograms as pounds.
    func testAConversionBetweenDifferentThingsIsRefused() {
        XCTAssertNil(HealthUnit.convert(1, from: "kg", to: "km"))
        XCTAssertNil(HealthUnit.convert(1, from: "degC", to: "kcal"))
        XCTAssertNil(HealthUnit.convert(1, from: "count", to: "kg"))
        XCTAssertNil(HealthUnit.convert(1, from: "count/min", to: "hr"))
        XCTAssertNil(HealthUnit.convert(1, from: "kg", to: "somethingNew"))
    }

    func testANonNumberIsRefusedRatherThanPropagated() {
        XCTAssertNil(HealthUnit.convert(.nan, from: "kg", to: "lb"))
        XCTAssertNil(HealthUnit.convert(.infinity, from: "kg", to: "lb"))
    }

    func testAValueAlreadyInTheRightUnitIsUntouched() {
        XCTAssertEqual(HealthUnit.convert(72.5, from: "kg", to: "kg"), 72.5)
    }

    // MARK: - Which group a reading belongs to

    /// Distance and body length are the same dimension and want opposite
    /// answers. Somebody who runs in miles does not want their waist in miles.
    func testDistanceAndBodyLengthAreToldApart() {
        XCTAssertEqual(
            UnitFamily.of(
                unit: "m",
                typeIdentifier: "HKQuantityTypeIdentifierDistanceWalkingRunning"
            ),
            .distance
        )
        XCTAssertEqual(
            UnitFamily.of(unit: "cm", typeIdentifier: "HKQuantityTypeIdentifierHeight"),
            .bodyLength
        )
        XCTAssertEqual(
            UnitFamily.of(
                unit: "cm",
                typeIdentifier: "HKQuantityTypeIdentifierWaistCircumference"
            ),
            .bodyLength
        )
    }

    func testAReadingWithNothingToConvertBelongsToNoGroup() {
        XCTAssertNil(
            UnitFamily.of(
                unit: "count",
                typeIdentifier: "HKQuantityTypeIdentifierStepCount"
            )
        )
        XCTAssertNil(
            UnitFamily.of(
                unit: "count/min",
                typeIdentifier: "HKQuantityTypeIdentifierHeartRate"
            )
        )
        XCTAssertNil(
            UnitFamily.of(unit: "%", typeIdentifier: "HKQuantityTypeIdentifierOxygenSaturation")
        )
    }

    /// Britain measures distance in miles and everything else in metric.
    /// Sending it all imperial would be as wrong as sending it all metric.
    func testTheRegionsResolveToTheUnitsThosePlacesActuallyUse() {
        let us = UnitPreferences.forRegion(Locale(identifier: "en_US"))
        XCTAssertEqual(us.units[.distance], "mi")
        XCTAssertEqual(us.units[.mass], "lb")
        XCTAssertEqual(us.units[.temperature], "degF")

        let uk = UnitPreferences.forRegion(Locale(identifier: "en_GB"))
        XCTAssertEqual(uk.units[.distance], "mi")
        XCTAssertEqual(uk.units[.mass], "kg", "Britain weighs itself in kilograms.")
        XCTAssertEqual(uk.units[.temperature], "degC")

        let de = UnitPreferences.forRegion(Locale(identifier: "de_DE"))
        XCTAssertEqual(de.units[.distance], "km")
        XCTAssertEqual(de.units[.mass], "kg")
    }

    // MARK: - The value and its unit move together

    private func destination(
        _ units: [UnitFamily: String],
        format: DeliveryFormat = .ndjson
    ) -> Destination {
        var options: [String: String] = [:]
        for (family, unit) in units {
            options[family.settingKey] = unit
        }
        return Destination(
            name: "Home server",
            kind: .restAPI,
            format: format,
            endpointURL: URL(string: "https://example.com/health"),
            options: options
        )
    }

    /// A marathon as Health would have recorded it, written out by hand.
    private let marathon = Data(
        (
            #"{"id":"run","kind":"quantity","quantity":{"description":"42195 m","unit":"m","value":42195},"startDate":"2026-08-22T09:00:00.000Z","type":"HKQuantityTypeIdentifierDistanceWalkingRunning"}"#
                + "\n"
        ).utf8
    )

    func testAConvertedValueCarriesTheUnitItWasConvertedTo() throws {
        let converted = PayloadUnits.apply(
            UnitPreferences(units: [.distance: "mi"]),
            to: marathon,
            format: .ndjson
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(converted.dropLast())
            ) as? [String: Any]
        )
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])

        XCTAssertEqual(quantity["unit"] as? String, "mi")
        XCTAssertEqual(
            try XCTUnwrap(quantity["value"] as? Double),
            26.219,
            accuracy: 0.001
        )
        XCTAssertEqual(
            quantity["convertedFrom"] as? String,
            "m",
            "A receiver has to be able to tell a converted reading from a native one."
        )
    }

    /// HealthKit's own rendering was of the original number in the original
    /// unit. Left alone it would contradict the two fields beside it.
    func testTheDescriptionIsRewrittenRatherThanLeftContradictingTheValue() throws {
        let converted = PayloadUnits.apply(
            UnitPreferences(units: [.distance: "mi"]),
            to: marathon,
            format: .ndjson
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(converted.dropLast())
            ) as? [String: Any]
        )
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        let description = try XCTUnwrap(quantity["description"] as? String)

        XCTAssertTrue(description.hasSuffix(" mi"), description)
        XCTAssertFalse(description.contains("42195"), description)
    }

    func testAReadingInAGroupWithNoPreferenceIsUntouched() {
        let steps = Data(
            (
                #"{"id":"s","kind":"quantity","quantity":{"unit":"count","value":900},"startDate":"2026-08-22T09:00:00.000Z","type":"HKQuantityTypeIdentifierStepCount"}"#
                    + "\n"
            ).utf8
        )

        XCTAssertEqual(
            PayloadUnits.apply(
                UnitPreferences(units: [.distance: "mi", .mass: "lb"]),
                to: steps,
                format: .ndjson
            ),
            steps,
            "Byte for byte."
        )
    }

    func testADestinationWithNoPreferencesSendsExactlyWhatItAlwaysDid() {
        XCTAssertEqual(
            PayloadUnits.apply(.asHealthProvides, to: marathon, format: .ndjson),
            marathon
        )
    }

    // MARK: - Every format that offers the setting honours it

    func testCSVConvertsTheValueAndTheUnitColumnTogether() throws {
        let csv = Data(
            (
                "id,type,kind,startDate,endDate,value,unit,sourceName,deleted\n"
                + "a,HKQuantityTypeIdentifierBodyMass,quantity,"
                + "2026-08-22T09:00:00.000Z,2026-08-22T09:00:00.000Z,"
                + "70,kg,Watch,false\n"
            ).utf8
        )

        let converted = PayloadUnits.apply(
            UnitPreferences(units: [.mass: "lb"]),
            to: csv,
            format: .csv
        )
        let rows = String(decoding: converted, as: UTF8.self)
            .split(separator: "\n")
        let fields = PayloadDivision.csvFields(String(rows[1]))

        XCTAssertEqual(fields[6], "lb")
        XCTAssertEqual(
            try XCTUnwrap(Double(fields[5])),
            154.3236,
            accuracy: 0.0001,
            "70 kg is 154.32 lb."
        )
        XCTAssertTrue(
            String(rows[0]).hasPrefix("id,type,kind"),
            "The header row is not a reading and must not be touched."
        )
    }

    /// A grouped payload carries the unit twice — on the metric and, in some
    /// shapes, on every point — and both have to move or they disagree.
    func testMetricsJSONConvertsEveryPointAndTheMetricsOwnUnit() throws {
        let metrics = Data(
            #"{"data":{"metrics":[{"data":[{"date":"2026-08-22T09:00:00.000Z","qty":70},{"date":"2026-08-23T09:00:00.000Z","qty":71}],"name":"weight_body_mass","units":"kg"}]}}"#
                .utf8
        )

        let converted = PayloadUnits.apply(
            UnitPreferences(units: [.mass: "lb"]),
            to: metrics,
            format: .metrics
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: converted) as? [String: Any]
        )
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let list = try XCTUnwrap(data["metrics"] as? [[String: Any]])
        let points = try XCTUnwrap(list[0]["data"] as? [[String: Any]])

        XCTAssertEqual(list[0]["units"] as? String, "lb")
        XCTAssertEqual(list[0]["convertedFrom"] as? String, "kg")
        XCTAssertEqual(
            try XCTUnwrap(points[0]["qty"] as? Double),
            154.3236,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(points[1]["qty"] as? Double),
            156.528,
            accuracy: 0.001,
            "71 kg is 156.53 lb."
        )
    }

    /// The unit is a tag inside a line whose escaping rules differ by position,
    /// and rewriting it in place is how a batch gets quietly corrupted. Not
    /// offering the setting is better than offering it and not applying it.
    func testLineProtocolIsLeftAloneAndSaysSo() {
        let line = Data("health,type=body_mass,unit=kg value=70.0 1787216400000000000\n".utf8)

        XCTAssertFalse(PayloadUnits.applies(to: .influx))
        XCTAssertEqual(
            PayloadUnits.apply(
                UnitPreferences(units: [.mass: "lb"]),
                to: line,
                format: .influx
            ),
            line
        )
    }

    // MARK: - Through the engine

    func testTheChannelReceivesTheConvertedPayload() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        let destination = destination([.distance: "mi"])
        try await engine.save(destination)

        _ = try await engine.deliver(
            DeliveryBatch(
                id: DeliveryBatch.identifier(for: marathon),
                sequence: 0,
                createdAt: .now,
                recordCount: 1,
                payload: marathon,
                format: .ndjson
            ),
            to: destination
        )

        let sent = await channel.payloads()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(sent[0].dropLast())
            ) as? [String: Any]
        )
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["unit"] as? String, "mi")
        XCTAssertEqual(
            try XCTUnwrap(quantity["value"] as? Double),
            26.219,
            accuracy: 0.001
        )
    }

    /// Two batches holding the same readings in different units are different
    /// bytes and have to be different batches, or a receiver honouring the
    /// idempotency key keeps whichever arrived first and discards the other.
    func testConvertingChangesTheBatchIdentifier() {
        let original = DeliveryBatch(
            id: DeliveryBatch.identifier(for: marathon),
            sequence: 0,
            createdAt: .now,
            recordCount: 1,
            payload: marathon,
            format: .ndjson
        )

        let converted = DeliveryEngine.inChosenUnits(
            original,
            for: destination([.distance: "mi"])
        )
        let untouched = DeliveryEngine.inChosenUnits(original, for: destination([:]))

        XCTAssertNotEqual(converted.id, original.id)
        XCTAssertEqual(converted.id, DeliveryBatch.identifier(for: converted.payload))
        XCTAssertEqual(converted.recordCount, 1, "A conversion adds and removes nothing.")
        XCTAssertEqual(untouched.id, original.id, "And an untouched batch keeps its key.")
    }

    /// Unlike a format or a precision, an unrecognised unit cannot mislabel
    /// anything: the reading goes out in the unit Health gave it, correctly
    /// named. Parking the destination would cost the user their data to protect
    /// them from nothing.
    func testAnUnrecognisedStoredUnitIsIgnoredRatherThanParkingTheDestination() {
        let destination = Destination(
            name: "n",
            kind: .restAPI,
            options: [UnitFamily.mass.settingKey: "furlongs"]
        )

        XCTAssertTrue(destination.isUsable)
        XCTAssertTrue(destination.unitPreferences.isEmpty)
        XCTAssertEqual(
            PayloadUnits.apply(
                destination.unitPreferences,
                to: marathon,
                format: .ndjson
            ),
            marathon
        )
    }

    func testEveryOfferedUnitCanActuallyBeConvertedToWithinItsGroup() {
        for family in UnitFamily.allCases {
            for source in family.choices {
                for target in family.choices {
                    XCTAssertTrue(
                        HealthUnit.canConvert(from: source, to: target),
                        "\(family.rawValue) offers \(source) and \(target), which "
                            + "Hozz cannot convert between."
                    )
                }
            }
        }
    }

    /// A picker offering `fl_oz_us` to choose between is a picker nobody can
    /// read. "mmHg" is exempt because it is already how the unit is written
    /// everywhere a blood pressure appears.
    func testEveryOfferedUnitHasAReadableName() {
        let alreadyReadable: Set<String> = ["mmHg"]
        for family in UnitFamily.allCases {
            for unit in family.choices where !alreadyReadable.contains(unit) {
                XCTAssertNotEqual(
                    UnitFamily.displayName(forUnit: unit),
                    unit,
                    "\(unit) needs a name someone can read."
                )
            }
        }
    }
}
