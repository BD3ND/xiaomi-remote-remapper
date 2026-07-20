import Foundation

final class ConfigurationStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private(set) var configuration: AppConfiguration

    var mappings: [KeyMapping] {
        guard let selectedDeviceID = configuration.selectedDeviceID,
              let profile = configuration.deviceProfiles?.first(where: { $0.deviceID == selectedDeviceID }) else {
            return configuration.mappings
        }
        return profile.mappings
    }

    private var activeProfile: RemoteProfile? {
        guard let selectedDeviceID = configuration.selectedDeviceID else { return nil }
        return configuration.deviceProfiles?.first(where: { $0.deviceID == selectedDeviceID })
    }

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
        var updated = mappings
        guard let index = updated.firstIndex(where: { $0.usage == usage }) else { return }
        updated[index].action = action
        setActiveMappings(updated)
        try save()
    }

    @discardableResult
    func learnUsage(_ usage: HIDUsage) throws -> Bool {
        var updated = mappings
        guard !updated.contains(where: { $0.usage == usage }) else { return false }
        let keyName: String
        if activeProfile?.isKnownXiaomiRemote == true {
            keyName = KeyMapping.learnedName(for: usage)
        } else {
            keyName = "按键 \(updated.count + 1)"
        }
        updated.append(
            KeyMapping(usage: usage, action: .logOnly, keyName: keyName)
        )
        setActiveMappings(updated)
        try save()
        return true
    }

    func renameMapping(for usage: HIDUsage, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = mappings
        guard let index = updated.firstIndex(where: { $0.usage == usage }) else { return }
        updated[index].keyName = String(trimmed.prefix(40))
        setActiveMappings(updated)
        try save()
    }

    func deleteMapping(for usage: HIDUsage) throws {
        var updated = mappings
        updated.removeAll(where: { $0.usage == usage })
        setActiveMappings(updated)
        try save()
    }

    func bindSerial(_ serial: String) throws {
        configuration.boundSerial = serial
        try save()
    }

    func selectDevice(_ device: RemoteDeviceDescriptor) throws {
        var profiles = configuration.deviceProfiles ?? []
        if let index = profiles.firstIndex(where: { $0.deviceID == device.id }) {
            profiles[index].deviceName = device.name
            profiles[index].vendorID = device.vendorID
            profiles[index].productID = device.productID
        } else {
            profiles.append(
                RemoteProfile(
                    deviceID: device.id,
                    deviceName: device.name,
                    vendorID: device.vendorID,
                    productID: device.productID,
                    mappings: device.isKnownXiaomiRemote ? AppConfiguration.defaultMappings : []
                )
            )
        }
        configuration.deviceProfiles = profiles
        configuration.selectedDeviceID = device.id
        configuration.selectedDeviceName = device.name
        configuration.boundSerial = device.serial
        try save()
    }

    func clearSerial() throws {
        configuration.boundSerial = nil
        configuration.selectedDeviceID = nil
        configuration.selectedDeviceName = nil
        try save()
    }

    func restoreDefaults() throws {
        let serial = configuration.boundSerial
        let selectedDeviceID = configuration.selectedDeviceID
        let selectedDeviceName = configuration.selectedDeviceName
        let profiles = configuration.deviceProfiles
        configuration = .defaults
        configuration.boundSerial = serial
        configuration.selectedDeviceID = selectedDeviceID
        configuration.selectedDeviceName = selectedDeviceName
        configuration.deviceProfiles = profiles
        setActiveMappings(activeProfile?.isKnownXiaomiRemote == true ? AppConfiguration.defaultMappings : [])
        try save()
    }

    private func setActiveMappings(_ mappings: [KeyMapping]) {
        guard let selectedDeviceID = configuration.selectedDeviceID,
              var profiles = configuration.deviceProfiles,
              let index = profiles.firstIndex(where: { $0.deviceID == selectedDeviceID }) else {
            configuration.mappings = mappings
            return
        }
        profiles[index].mappings = mappings
        configuration.deviceProfiles = profiles
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }

    private static func mergedWithDefaults(_ saved: AppConfiguration) -> (configuration: AppConfiguration, changed: Bool) {
        let savedSchema = saved.schemaVersion ?? 1
        var mappings = saved.mappings
        var changed = false
        if savedSchema < 6 {
            for defaultMapping in AppConfiguration.defaultMappings {
                if let index = mappings.firstIndex(where: { $0.usage == defaultMapping.usage }) {
                    if mappings[index].keyName != defaultMapping.keyName {
                        mappings[index].keyName = defaultMapping.keyName
                        changed = true
                    }
                } else {
                    mappings.append(defaultMapping)
                    changed = true
                }
            }
        }

        // Schema 2 deliberately returns Home and Grave/Tilde to macOS. Older
        // saved configurations contained app-generated actions for both keys.
        if savedSchema < 2 {
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
        var profiles = saved.deviceProfiles ?? []
        if profiles.isEmpty,
           let selectedDeviceID = saved.selectedDeviceID {
            profiles.append(
                RemoteProfile(
                    deviceID: selectedDeviceID,
                    deviceName: saved.selectedDeviceName ?? "小米语音遥控器",
                    vendorID: HIDService.vendorID,
                    productID: HIDService.productID,
                    mappings: mappings
                )
            )
            changed = true
        }
        if savedSchema < 6 {
            for profileIndex in profiles.indices {
                if profiles[profileIndex].vendorID == nil {
                    profiles[profileIndex].vendorID = HIDService.vendorID
                    profiles[profileIndex].productID = HIDService.productID
                    changed = true
                }
                for defaultMapping in AppConfiguration.defaultMappings {
                    if let mappingIndex = profiles[profileIndex].mappings.firstIndex(where: { $0.usage == defaultMapping.usage }) {
                        if profiles[profileIndex].mappings[mappingIndex].keyName != defaultMapping.keyName {
                            profiles[profileIndex].mappings[mappingIndex].keyName = defaultMapping.keyName
                            changed = true
                        }
                    } else {
                        profiles[profileIndex].mappings.append(defaultMapping)
                        changed = true
                    }
                }
            }
        }

        return (
            AppConfiguration(
                schemaVersion: AppConfiguration.currentSchemaVersion,
                boundSerial: saved.boundSerial,
                selectedDeviceID: saved.selectedDeviceID,
                selectedDeviceName: saved.selectedDeviceName,
                mappings: mappings,
                deviceProfiles: profiles
            ),
            changed || saved.schemaVersion != AppConfiguration.currentSchemaVersion
        )
    }
}
