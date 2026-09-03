import Foundation

/// How much Hozz is willing to put in one request.
///
/// The number that matters belongs to the server, not the phone. An nginx in
/// front of somebody's home API refuses a body over one megabyte by default,
/// Cloudflare's free tier stops at a hundred, and a small PHP endpoint has its
/// own idea — and in every case the whole batch is refused, so a person who has
/// selected a lot of metrics simply never receives anything and is told only
/// "HTTP 413".
///
/// Splitting is off by default. It changes how many requests an existing
/// destination receives, and a setup that works today should go on working
/// untouched after an update.
public enum RequestSize {
    /// Below this a part could not hold one ordinary record plus its framing,
    /// and the split would be all overhead.
    public static let minimum = 16 * 1_024

    public static let choices: [Int] = [
        256 * 1_024,
        512 * 1_024,
        1_024 * 1_024,
        4 * 1_024 * 1_024
    ]

    public static func displayName(for bytes: Int) -> String {
        bytes >= 1_024 * 1_024
            ? "\(bytes / (1_024 * 1_024)) MB"
            : "\(bytes / 1_024) KB"
    }

    /// Why someone would pick this one.
    public static func explanation(for bytes: Int) -> String {
        switch bytes {
        case ..<(512 * 1_024):
            "Fits tight proxy limits; sends more requests."
        case ..<(1_024 * 1_024):
            "Safe below nginx's default 1 MB limit."
        case 1_024 * 1_024:
            "Matches nginx's default limit."
        default:
            "For servers that accept large bodies; fewer requests."
        }
    }
}
