import Foundation

/// Identifiers both halves of Hozz have to agree on.
///
/// Kept here rather than in the receiver because the phone browses for exactly
/// what the Mac advertises, and the two live in different modules on different
/// platforms. A duplicated string literal would drift, and the failure would be
/// silent: the Mac would advertise and the phone would simply never find it.
public enum HozzService {
    /// The Bonjour service type a Hozz receiver advertises.
    public static let bonjourType = "_hozz._tcp"

    /// The port a receiver listens on.
    ///
    /// Fixed, and shared by both halves, so the phone can ask an address
    /// directly when neither Bonjour nor iCloud can say where a computer is.
    /// An ephemeral port would change on every launch and leave a saved
    /// destination pointing at nothing.
    public static let defaultPort: UInt16 = 54330
}
