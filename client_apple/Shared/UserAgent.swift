import Foundation
import QotKit

/// `qot-ios/<version> (iOS <version>; <model>)`, sent with every request.
/// Shared by the app and its extensions.
enum UserAgent {
    static let value: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let parts = [os.majorVersion, os.minorVersion] + (os.patchVersion > 0 ? [os.patchVersion] : [])
        return ServerAPI.userAgent(
            appVersion: version, osName: "iOS",
            osVersion: parts.map(String.init).joined(separator: "."), model: modelIdentifier())
    }()

    /// e.g. `iPhone18,1`; in the simulator, the simulated model's.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
