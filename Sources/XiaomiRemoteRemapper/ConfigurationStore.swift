import Foundation

final class ConfigurationStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private(set) var configuration: AppConfiguration

    init(fileURL: URL? = nil) {
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/XiaomiRemoteRemapper/config.json")
        self.fileURL = fileURL ?? defaultURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var shouldSaveMigration = false
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? decoder.decode(AppConfiguration.self, from: data) {
            let result = ConfigurationStore.mergedWithDefaults(decoded)
            configuration = result.configuration
            shouldSaveMigration = result.changed
        } else {
            configuration = .defaults
        }

        if shouldSaveMigration {
            do {
                try save()
                AppLogger.shared.log("configuration_migrated schema=\(AppConfiguration.currentSchemaVersion)")
            } catch {
                AppLogger.shared.log("configuration_migration_save_failed error=\(error)")
            }
        }
    }

    func setAction(_ action: RemoteAction, for usage: HIDUsage) throws {
        guard let index = configuration.mappings.firstIndex(where: { $0.usage == usage }) else { return }
        configuration.mappings[index].action = action
        try save()
    }

    func bindSerial(_ serial: String) throws {
        configuration.boundSerial = serial
        try save()
    }

    func clearSerial() throws {
        configuration.boundSerial = nil
        try save()
    }

    func restoreDefaults() throws {
        let serial = configuration.boundSerial
        configuration = .defaults
        configuration.boundSerial = serial
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }

    private static func mergedWithDefaults(_ saved: AppConfiguration) -> (configuration: AppConfiguration, changed: Bool) {
        var mappings = saved.mappings
        var changed = false
        for defaultMapping in AppConfiguration.defaultMappings
            where !mappings.contains(where: { $0.usage == defaultMapping.usage }) {
            mappings.append(defaultMapping)
            changed = true
        }

        // Schema 2 deliberately returns Home and Grave/Tilde to macOS. Older
        // saved configurations contained app-generated actions for both keys.
        if (saved.schemaVersion ?? 1) < 2 {
            let passThroughUsages = [
                HIDUsage(page: 7, usage: 74),
                HIDUsage(page: 7, usage: 53)
            ]
            for usage in passThroughUsages {
                if let index = mappings.firstIndex(where: { $0.usage == usage }) {
                    mappings[index].action = .passThrough
                }
            }
            changed = true
        }
        return (
            AppConfiguration(
                schemaVersion: AppConfiguration.currentSchemaVersion,
                boundSerial: saved.boundSerial,
                mappings: mappings
            ),
            changed || saved.schemaVersion != AppConfiguration.currentSchemaVersion
        )
    }
}
