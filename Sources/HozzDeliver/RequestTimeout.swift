import Foundation

/// How long Hozz waits for a destination to answer.
///
/// One number, offered as a short list rather than a free text field. The
/// failure this exists to fix is a large batch posted to a small computer — a
/// Home Assistant on a Raspberry Pi writing to an SD card — where the server is
/// working perfectly and simply has not finished. `URLSession` gives up after
/// sixty seconds by default and reports a transport failure, which reads to the
/// user as "your server is broken" and is not true.
///
/// The other direction matters too. A phone holding a request open for an hour
/// against a computer that is switched off is a phone spending battery to learn
/// something it could have learned in ten seconds, so the shortest option is
/// there for people on a fast local network who would rather retry sooner.
public enum RequestTimeout {
    /// What `URLSession` would do anyway, kept as the default so an existing
    /// destination behaves on this build exactly as it did on the last one.
    public static let `default`: TimeInterval = 60

    /// The choices offered. The upper end matches what a person with a slow
    /// self-hosted server actually needs; beyond an hour iOS will have
    /// suspended a background app long before the request could finish, so
    /// offering more would be offering something that cannot happen.
    public static let choices: [TimeInterval] = [10, 30, 60, 300, 1_800, 3_600]

    /// Values accepted from storage. Wider than ``choices`` so a number written
    /// by a newer build, or by hand, is honoured rather than discarded.
    public static let range: ClosedRange<TimeInterval> = 1...3_600

    public static func displayName(for seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60:
            "\(Int(seconds)) seconds"
        case 60:
            "1 minute"
        case ..<3_600:
            "\(Int(seconds / 60)) minutes"
        case 3_600:
            "1 hour"
        default:
            "\(Int(seconds / 3_600)) hours"
        }
    }

    /// What choosing this actually costs, for the two options where it is not
    /// obvious.
    public static func explanation(for seconds: TimeInterval) -> String {
        switch seconds {
        case ..<30:
            "Fast to find out something is wrong. Too short for a server that "
            + "takes its time with a large batch, which would then look broken "
            + "when it is only slow."
        case 30...300:
            "Long enough for a home server writing to an SD card, short enough "
            + "that an unreachable one is noticed the same day."
        default:
            "For a server that genuinely needs minutes. iOS suspends a "
            + "background app long before an hour is up, so a wait this long "
            + "usually only completes while Hozz is open on screen."
        }
    }
}
