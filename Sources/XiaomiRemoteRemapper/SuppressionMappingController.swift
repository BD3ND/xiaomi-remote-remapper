import Foundation

final class SuppressionMappingController {
    private static let matchingJSON = "{\"VendorID\":10007,\"ProductID\":12984}"
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
    func apply(mappings: [KeyMapping]) -> Bool {
        set(Self.suppressionJSON(for: mappings), operation: "apply")
    }

    @discardableResult
    func clear() -> Bool {
        set("{\"UserKeyMapping\":[]}", operation: "clear")
    }

    private func set(_ propertyJSON: String, operation: String) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = [
            "property",
            "--matching", Self.matchingJSON,
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
