import Foundation
import HealthKit
import HozzCore

/// Encodes a State of Mind log: a mood entry rather than a measurement.
///
/// The care here is about what a blank would mean. Valence runs from -1 to 1
/// and **zero is neutral, not missing** — so it is always written, never
/// omitted and never defaulted. Labels and associations are lists the person
/// chose from, and an empty list means they chose none, which is a fact rather
/// than an absence.
///
/// Every enumeration is written as a name *and* the number behind it, so a
/// feeling Apple adds in a later release still arrives as something, rather
/// than becoming a gap in someone's mood history.
@available(iOS 18.0, *)
public enum StateOfMindEncoding {
    public static let typeIdentifier = "HKDataTypeStateOfMind"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    static func object(for sample: HKStateOfMind) -> [String: Any] {
        [
            "kindOfEntry": named(kind: sample.kind),
            // Written unconditionally. A neutral mood is a reading.
            "valence": sample.valence,
            "valenceClassification": named(
                classification: sample.valenceClassification
            ),
            // Order is the order Health returned, which is the order the
            // person picked them in.
            "labels": sample.labels.map(named(label:)),
            "associations": sample.associations.map(named(association:))
        ]
    }

    static func named(kind: HKStateOfMind.Kind) -> [String: Any] {
        let name: String = switch kind {
        case .momentaryEmotion: "momentaryEmotion"
        case .dailyMood: "dailyMood"
        @unknown default: "unrecognisedByHozz"
        }
        return ["name": name, "rawValue": kind.rawValue]
    }

    static func named(
        classification: HKStateOfMind.ValenceClassification
    ) -> [String: Any] {
        let name: String = switch classification {
        case .veryUnpleasant: "veryUnpleasant"
        case .unpleasant: "unpleasant"
        case .slightlyUnpleasant: "slightlyUnpleasant"
        case .neutral: "neutral"
        case .slightlyPleasant: "slightlyPleasant"
        case .pleasant: "pleasant"
        case .veryPleasant: "veryPleasant"
        @unknown default: "unrecognisedByHozz"
        }
        return ["name": name, "rawValue": classification.rawValue]
    }

    static func named(label: HKStateOfMind.Label) -> [String: Any] {
        ["name": labelNames[label] ?? "unrecognisedByHozz", "rawValue": label.rawValue]
    }

    static func named(association: HKStateOfMind.Association) -> [String: Any] {
        [
            "name": associationNames[association] ?? "unrecognisedByHozz",
            "rawValue": association.rawValue
        ]
    }

    private static let labelNames: [HKStateOfMind.Label: String] = [
        .amazed: "amazed",
        .amused: "amused",
        .angry: "angry",
        .annoyed: "annoyed",
        .anxious: "anxious",
        .ashamed: "ashamed",
        .brave: "brave",
        .calm: "calm",
        .confident: "confident",
        .content: "content",
        .disappointed: "disappointed",
        .discouraged: "discouraged",
        .disgusted: "disgusted",
        .drained: "drained",
        .embarrassed: "embarrassed",
        .excited: "excited",
        .frustrated: "frustrated",
        .grateful: "grateful",
        .guilty: "guilty",
        .happy: "happy",
        .hopeful: "hopeful",
        .hopeless: "hopeless",
        .indifferent: "indifferent",
        .irritated: "irritated",
        .jealous: "jealous",
        .joyful: "joyful",
        .lonely: "lonely",
        .overwhelmed: "overwhelmed",
        .passionate: "passionate",
        .peaceful: "peaceful",
        .proud: "proud",
        .relieved: "relieved",
        .sad: "sad",
        .satisfied: "satisfied",
        .scared: "scared",
        .stressed: "stressed",
        .surprised: "surprised",
        .worried: "worried"
    ]

    private static let associationNames: [HKStateOfMind.Association: String] = [
        .community: "community",
        .currentEvents: "currentEvents",
        .dating: "dating",
        .education: "education",
        .family: "family",
        .fitness: "fitness",
        .friends: "friends",
        .health: "health",
        .hobbies: "hobbies",
        .identity: "identity",
        .money: "money",
        .partner: "partner",
        .selfCare: "selfCare",
        .spirituality: "spirituality",
        .tasks: "tasks",
        .travel: "travel",
        .weather: "weather",
        .work: "work"
    ]
}
