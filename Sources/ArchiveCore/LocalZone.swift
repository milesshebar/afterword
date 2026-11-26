import Foundation

/// The time zone that day-sized inputs are read in (an import's `--until` / `--since` day, a Facebook page with no offset in
/// its header, the default label of a Contacts import): `<PREFIX>_TIME_ZONE` (an IANA name) when set, else this machine's zone.
public enum LocalZone {
    public static var environmentKey: String { Product.environmentPrefix + "_TIME_ZONE" }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeZone {
        environment[environmentKey].flatMap { TimeZone(identifier: $0) } ?? TimeZone.current
    }
}
