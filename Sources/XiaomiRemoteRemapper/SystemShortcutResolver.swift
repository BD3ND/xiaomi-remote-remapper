import ApplicationServices
import Foundation

struct SystemShortcutResolution: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let source: String
    let isEnabled: Bool

    var diagnosticDescription: String {
        "source=\(source) enabled=\(isEnabled) keyCode=\(keyCode) flags=\(flags.rawValue)"
    }
}

enum SystemShortcutResolver {
    enum Shortcut: Int {
        case missionControl = 32
        case showDesktop = 36
        case spotlight = 64

        var fallback: SystemShortcutResolution {
            switch self {
            case .missionControl:
                return SystemShortcutResolution(
                    keyCode: 126,
                    flags: .maskControl,
                    source: "apple_default",
                    isEnabled: true
                )
            case .showDesktop:
                return SystemShortcutResolution(
                    keyCode: 4,
                    flags: .maskSecondaryFn,
                    source: "apple_default",
                    isEnabled: true
                )
            case .spotlight:
                return SystemShortcutResolution(
                    keyCode: 49,
                    flags: .maskCommand,
                    source: "apple_default",
                    isEnabled: true
                )
            }
        }
    }

    static func resolve(_ shortcut: Shortcut) -> SystemShortcutResolution {
        let preferences = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any]
        return resolve(shortcut, preferences: preferences)
    }

    static func resolve(
        _ shortcut: Shortcut,
        preferences: [String: Any]?
    ) -> SystemShortcutResolution {
        let fallback = shortcut.fallback
        guard let entry = preferences?[String(shortcut.rawValue)] as? [String: Any] else {
            return fallback
        }
        guard (entry["enabled"] as? NSNumber)?.boolValue != false else {
            return SystemShortcutResolution(
                keyCode: fallback.keyCode,
                flags: fallback.flags,
                source: "user_configuration_disabled",
                isEnabled: false
            )
        }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCodeNumber = parameters[1] as? NSNumber,
              let flagsNumber = parameters[2] as? NSNumber else {
            return SystemShortcutResolution(
                keyCode: fallback.keyCode,
                flags: fallback.flags,
                source: "apple_default_invalid_config",
                isEnabled: true
            )
        }

        let keyCodeValue = keyCodeNumber.uint64Value
        guard keyCodeValue < UInt64(UInt16.max) else {
            return SystemShortcutResolution(
                keyCode: fallback.keyCode,
                flags: fallback.flags,
                source: "apple_default_unassigned",
                isEnabled: true
            )
        }
        return SystemShortcutResolution(
            keyCode: CGKeyCode(keyCodeValue),
            flags: CGEventFlags(rawValue: flagsNumber.uint64Value),
            source: "user_configuration",
            isEnabled: true
        )
    }
}
