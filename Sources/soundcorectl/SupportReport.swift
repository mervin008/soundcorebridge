import Foundation

/// An allowlisted summary: never accepts Bluetooth names, addresses, raw
/// packets, or logs, which can contain identifiers belonging to other hosts.
struct SupportReport {
    let profile: DeviceProfile
    let state: DeviceState?
    let connected: Bool
    let channel: UInt8?

    var text: String {
        // A disconnected controller can still hold the previous device's state.
        let current = connected ? state : nil
        let identified = current != nil
        let features = identified ? DeviceFeature.allCases.filter(profile.supports).map(\.rawValue) : []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "source build"
        return """
        SoundcoreBridge device support report
        Report format: 1
        App version: \(version)
        macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Connection: \(connected ? "Connected" : "Not connected")
        Model code: \(Self.field(current?.model))
        Firmware: \(Self.field(current?.firmware))
        Profile: \(identified ? profile.displayName : "Not identified")
        Control support: \(identified ? (profile.allowsWrites ? "Verified model" : "Read-only; model not verified") : "Unavailable until identified")
        RFCOMM channel: \(connected ? channel.map(String.init) ?? "Not available" : "Not available")
        Profile features: \(features.isEmpty ? "None identified" : features.joined(separator: ", "))

        Bluetooth names, addresses, raw packets, and logs are excluded.
        Unknown-model fields are tentative until confirmed against a capture.
        Add your headphone model name and the problem when submitting an issue.
        """
    }

    private static func field(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 16,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 46 || $0 == 45 }) else { return "Not available" }
        return value
    }
}
