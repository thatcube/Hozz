import Foundation

/// Maps HealthKit identifiers to the short metric names used by the widely
/// deployed Health Auto Export payload schema.
///
/// This exists for interoperability, not imitation. That schema already has an
/// ecosystem around it — Home Assistant integrations, Grafana dashboards, and a
/// community ingest server — and someone who has already built against it
/// should be able to move to Hozz without rewriting any of it.
public enum MetricNameMap {
    public static func metricName(for identifier: String) -> String {
        if let known = names[identifier] {
            return known
        }
        // An unmapped type still gets a stable, predictable name rather than
        // being dropped, so a receiver can handle types Hozz has not curated.
        var stripped = identifier
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier"]
        where stripped.hasPrefix(prefix) {
            stripped.removeFirst(prefix.count)
            break
        }
        return snakeCased(stripped)
    }

    static func snakeCased(_ value: String) -> String {
        var result = ""
        for (index, character) in value.enumerated() {
            if character.isUppercase, index > 0 {
                result.append("_")
            }
            result.append(Character(character.lowercased()))
        }
        return result
    }

    private static let names: [String: String] = [
        // Activity and exercise
        "HKQuantityTypeIdentifierStepCount": "step_count",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "active_energy",
        "HKQuantityTypeIdentifierBasalEnergyBurned": "basal_energy_burned",
        "HKQuantityTypeIdentifierAppleExerciseTime": "apple_exercise_time",
        "HKQuantityTypeIdentifierAppleMoveTime": "apple_move_time",
        "HKQuantityTypeIdentifierAppleStandTime": "apple_stand_time",
        "HKCategoryTypeIdentifierAppleStandHour": "apple_stand_hour",
        "HKQuantityTypeIdentifierDistanceCycling": "cycling_distance",
        "HKQuantityTypeIdentifierDistanceDownhillSnowSports": "downhill_snow_sports",
        "HKQuantityTypeIdentifierDistanceSwimming": "swimming_distance",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "walking_running_distance",
        "HKQuantityTypeIdentifierDistanceWheelchair": "wheelchair_distance",
        "HKQuantityTypeIdentifierFlightsClimbed": "flights_climbed",
        "HKQuantityTypeIdentifierPushCount": "wheelchair_push_count",
        "HKQuantityTypeIdentifierSwimmingStrokeCount": "swim_stroke_count",
        "HKQuantityTypeIdentifierVO2Max": "vo2max",
        "HKQuantityTypeIdentifierPhysicalEffort": "physical_effort",
        "HKQuantityTypeIdentifierCyclingCadence": "cycling_cadence",
        "HKQuantityTypeIdentifierCyclingFunctionalThresholdPower":
            "cycling_functional_threshold_power",
        "HKQuantityTypeIdentifierCyclingPower": "cycling_power",
        "HKQuantityTypeIdentifierCyclingSpeed": "cycling_speed",
        "HKQuantityTypeIdentifierRunningPower": "running_power",
        "HKQuantityTypeIdentifierRunningSpeed": "running_speed",
        "HKQuantityTypeIdentifierRunningGroundContactTime": "running_ground_contact_time",
        "HKQuantityTypeIdentifierRunningStrideLength": "running_stride_length",
        "HKQuantityTypeIdentifierRunningVerticalOscillation":
            "running_vertical_oscillation",

        // Body measurements
        "HKQuantityTypeIdentifierHeight": "height",
        "HKQuantityTypeIdentifierBodyMass": "weight_body_mass",
        "HKQuantityTypeIdentifierWaistCircumference": "waist_circumference",
        "HKQuantityTypeIdentifierBodyFatPercentage": "body_fat_percentage",
        "HKQuantityTypeIdentifierBodyMassIndex": "body_mass_index",
        "HKQuantityTypeIdentifierLeanBodyMass": "lean_body_mass",

        // Cardiovascular
        "HKQuantityTypeIdentifierHeartRate": "heart_rate",
        "HKQuantityTypeIdentifierRestingHeartRate": "resting_heart_rate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "heart_rate_variability",
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": "cardio_recovery",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage": "walking_heart_rate",
        "HKQuantityTypeIdentifierAtrialFibrillationBurden": "atrial_fibrillation_burden",
        "HKQuantityTypeIdentifierBloodPressureSystolic": "blood_pressure_systolic",
        "HKQuantityTypeIdentifierBloodPressureDiastolic": "blood_pressure_diastolic",

        // Mobility
        "HKQuantityTypeIdentifierWalkingSpeed": "walking_speed",
        "HKQuantityTypeIdentifierWalkingStepLength": "walking_step_length",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage":
            "walking_asymmetry_percentage",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage":
            "walking_double_support_percentage",
        "HKQuantityTypeIdentifierSixMinuteWalkTestDistance":
            "six_minute_walking_test_distance",
        "HKQuantityTypeIdentifierStairAscentSpeed": "stair_speed_up",
        "HKQuantityTypeIdentifierStairDescentSpeed": "stair_speed_down",

        // Respiratory
        "HKQuantityTypeIdentifierRespiratoryRate": "respiratory_rate",
        "HKQuantityTypeIdentifierForcedExpiratoryVolume1": "forced_expiratory_volume",
        "HKQuantityTypeIdentifierForcedVitalCapacity": "forced_vital_capacity",
        "HKQuantityTypeIdentifierOxygenSaturation": "blood_oxygen_saturation",
        "HKQuantityTypeIdentifierPeripheralPerfusionIndex": "peripheral_perfusion_index",
        "HKQuantityTypeIdentifierPeakExpiratoryFlowRate": "peak_expiratory_flow_rate",
        "HKQuantityTypeIdentifierInhalerUsage": "inhaler_usage",

        // Temperature and environment
        "HKQuantityTypeIdentifierBodyTemperature": "body_temperature",
        "HKQuantityTypeIdentifierBasalBodyTemperature": "basal_body_temperature",
        "HKQuantityTypeIdentifierUnderwaterDepth": "under_water_depth",
        "HKQuantityTypeIdentifierWaterTemperature": "under_water_temperature",
        "HKQuantityTypeIdentifierUVExposure": "uv_exposure",
        "HKQuantityTypeIdentifierTimeInDaylight": "time_in_daylight",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure": "environmental_audio",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": "headphone_audio",

        // Sleep
        "HKCategoryTypeIdentifierSleepAnalysis": "sleep_analysis",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature":
            "apple_sleeping_wrist_temperature",
        "HKCategoryTypeIdentifierSleepApneaEvent": "breathing_disturbances",

        // Medical
        "HKQuantityTypeIdentifierInsulinDelivery": "insulin_delivery",
        "HKQuantityTypeIdentifierBloodGlucose": "blood_glucose",

        // Nutrition
        "HKQuantityTypeIdentifierDietaryEnergyConsumed": "dietary_energy",
        "HKQuantityTypeIdentifierDietaryWater": "dietary_water",
        "HKQuantityTypeIdentifierDietarySugar": "dietary_sugar",
        "HKQuantityTypeIdentifierDietaryCholesterol": "cholesterol",
        "HKQuantityTypeIdentifierDietaryCarbohydrates": "carbohydrates",
        "HKQuantityTypeIdentifierDietaryBiotin": "biotin",
        "HKQuantityTypeIdentifierDietaryCaffeine": "caffeine",
        "HKQuantityTypeIdentifierDietaryCalcium": "calcium",
        "HKQuantityTypeIdentifierDietaryChloride": "chloride",
        "HKQuantityTypeIdentifierDietaryChromium": "chromium",
        "HKQuantityTypeIdentifierDietaryCopper": "copper",
        "HKQuantityTypeIdentifierDietaryFiber": "fiber",
        "HKQuantityTypeIdentifierDietaryFolate": "folate",
        "HKQuantityTypeIdentifierDietaryIodine": "iodine",
        "HKQuantityTypeIdentifierDietaryIron": "iron",
        "HKQuantityTypeIdentifierDietaryMagnesium": "magnesium",
        "HKQuantityTypeIdentifierDietaryManganese": "manganese",
        "HKQuantityTypeIdentifierDietaryMolybdenum": "molybdenum",
        "HKQuantityTypeIdentifierDietaryFatMonounsaturated": "monosaturated_fat",
        "HKQuantityTypeIdentifierDietaryNiacin": "niacin",
        "HKQuantityTypeIdentifierDietaryPantothenicAcid": "pantothenic_acid",
        "HKQuantityTypeIdentifierDietaryFatPolyunsaturated": "polyunsaturated_fat",
        "HKQuantityTypeIdentifierDietaryPotassium": "potassium",
        "HKQuantityTypeIdentifierDietaryProtein": "protein",
        "HKQuantityTypeIdentifierDietaryRiboflavin": "riboflavin",
        "HKQuantityTypeIdentifierDietaryFatSaturated": "saturated_fat",
        "HKQuantityTypeIdentifierDietarySelenium": "selenium",
        "HKQuantityTypeIdentifierDietarySodium": "sodium",
        "HKQuantityTypeIdentifierDietaryThiamin": "thiamin",
        "HKQuantityTypeIdentifierDietaryFatTotal": "total_fat",
        "HKQuantityTypeIdentifierDietaryVitaminA": "vitamin_a",
        "HKQuantityTypeIdentifierDietaryVitaminB6": "vitamin_b6",
        "HKQuantityTypeIdentifierDietaryVitaminB12": "vitamin_b12",
        "HKQuantityTypeIdentifierDietaryVitaminC": "vitamin_c",
        "HKQuantityTypeIdentifierDietaryVitaminD": "vitamin_d",
        "HKQuantityTypeIdentifierDietaryVitaminE": "vitamin_e",
        "HKQuantityTypeIdentifierDietaryVitaminK": "vitamin_k",
        "HKQuantityTypeIdentifierDietaryZinc": "zinc",

        // Mindfulness and lifestyle
        "HKCategoryTypeIdentifierMindfulSession": "mindful_minutes",
        "HKCategoryTypeIdentifierSexualActivity": "sexual_activity",
        "HKQuantityTypeIdentifierElectrodermalActivity": "electrodermal_activity",
        "HKQuantityTypeIdentifierBloodAlcoholContent": "blood_alcohol_content",
        "HKCategoryTypeIdentifierHandwashingEvent": "handwashing",
        "HKQuantityTypeIdentifierNumberOfTimesFallen": "number_of_time_fallen",
        "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages":
            "number_of_alcoholic_beverages",
        "HKCategoryTypeIdentifierToothbrushingEvent": "toothbrushing"
    ]
}
