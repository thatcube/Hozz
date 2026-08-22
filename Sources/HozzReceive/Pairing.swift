import Foundation

/// A device that has been given the token.
public struct PairedDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let pairedAt: Date

    public init(id: UUID = UUID(), name: String, pairedAt: Date = .now) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

public enum PairingOutcome: Hashable, Sendable {
    case allowed(token: String)
    case needsApproval
}

/// Pairing rules, kept in one place because they are a security boundary.
///
/// The receiver has no endpoint that returns Health data — `GET /` reports only
/// that the service exists — so a token that leaked would let someone *inject*
/// records, not read them. That is why the first pairing can be automatic: the
/// worst case is polluted data on a computer the user controls, not disclosure,
/// and making every user perform a ceremony to prevent a narrow case is a poor
/// trade.
///
/// It is still not a free-for-all:
///
/// 1. Only the *first* device pairs automatically, and only while nothing has
///    ever paired. A stranger cannot quietly join months later.
/// 2. Every pairing is recorded and shown, so it is never invisible.
/// 3. The token can be rotated, which immediately invalidates every device.
public enum PairingPolicy {
    /// The longest device name that will be stored or shown, so a hostile name
    /// cannot push the real content off a dialog.
    public static let maximumDeviceNameLength = 60

    /// Trims a device name to something safe to display.
    ///
    /// A name arriving over the network is attacker-controlled. Control
    /// characters are removed so it cannot forge extra lines in a prompt, which
    /// is how someone gets tricked into approving something they did not read.
    public static func safeDeviceName(_ raw: String?) -> String {
        guard let raw else {
            return "An unknown device"
        }
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return "An unknown device"
        }
        return String(cleaned.prefix(maximumDeviceNameLength))
    }
}
