import Foundation

final class SuppressionMappingController {
    private static let legacyMatchingJSON = "{\"VendorID\":10007,\"ProductID\":12984}"
    private static let suppressedDestination = "0x700000000"

    static func suppressionJSON(for mappings: [KeyMapping]) -> String {
        let entries = mappings
            .filter { $0.action != .passThrough }
            .map { mapping in
                let source = String(format: "0x%08llx", (UInt64(mapping.usage.page) << 32) | UInt64(mapping.usage.usage))
                return "{\"HIDKeyboardModifierMappingSrc\":\(source),\"HIDKeyboardModifierMappingDst\":\(suppressedDestination)}"
            }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    @discardableResult
    func apply(mappings: [KeyMapping], deviceID: String) -> Bool {
        set(
            Self.suppressionJSON(for: mappings),
            matchingJSON: Self.matchingJSON(deviceID: deviceID),
            operation: "apply"
        )
    }

    @discardableResult
    func clear(deviceID: String) -> Bool {
        set(
            "{\"UserKeyMapping\":[]}",
            matchingJSON: Self.matchingJSON(deviceID: deviceID),
            operation: "clear"
        )
    }

    @discardableResult
    func clearLegacyBroadMapping() -> Bool {
        set(
            "{\"UserKeyMapping\":[]}",
            matchingJSON: Self.legacyMatchingJSON,
            operation: "clear_legacy_broad"
        )
    }

    static func matchingJSON(deviceID: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["PhysicalDeviceUniqueID": deviceID],
            options: [.sortedKeys]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func set(
        _ propertyJSON: String,
        matchingJSON: String,
        operation: String
    ) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = [
            "property",
            "--matching", matchingJSON,
            "--set", propertyJSON
        ]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let succeeded = process.terminationStatus == 0
            AppLogger.shared.log(
                "suppression_mapping operation=\(operation) success=\(succeeded) status=\(process.terminationStatus) detail=\(detail)"
            )
            return succeeded
        } catch {
            AppLogger.shared.log("suppression_mapping operation=\(operation) launch_failed=\(error)")
            return false
        }
    }
}
