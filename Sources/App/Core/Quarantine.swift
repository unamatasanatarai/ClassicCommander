import Foundation
import CoreServices

/// Files downloaded from servers get macOS's quarantine mark, as browsers do, so Gatekeeper checks
/// them (and warns) before they are opened or run.
public enum Quarantine {
    public static func mark(_ url: URL, origin: String?) {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "ClassicCommander",
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let origin = origin, let originURL = URL(string: origin) {
            properties[kLSQuarantineOriginURLKey as String] = originURL
        }
        try? (url as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }

    /// Whether a file carries the quarantine mark (for tests and diagnostics).
    public static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }
}
