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
            "Small enough for almost any server, including one behind a proxy "
            + "with a tight limit. More requests, each quick."
        case ..<(1_024 * 1_024):
            "A safe margin under the one-megabyte limit nginx applies unless "
            + "told otherwise."
        case 1_024 * 1_024:
            "The default limit for nginx, which sits in front of a great many "
            + "home servers. Right at it rather than under it."
        default:
            "For a server you know accepts large bodies. Fewer requests, and "
            + "less to redo if one of them fails."
        }
    }
}
