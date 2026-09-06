import Foundation

struct HIDUsage: Hashable, Codable, Comparable, CustomStringConvertible {
    let page: UInt32
    let usage: UInt32

    var description: String { "\(page):\(usage)" }

    var isLearnable: Bool {
        page > 0 && usage > 0 && usage != UInt32.max
    }

    static func decodedArrayUsage(page: UInt32, value: CFIndex) -> HIDUsage? {
        guard page > 0, value > 0, UInt64(value) < UInt64(UInt32.max) else { return nil }
        return HIDUsage(page: page, usage: UInt32(value))
    }

    static func < (lhs: HIDUsage, rhs: HIDUsage) -> Bool {
        lhs.page == rhs.page ? lhs.usage < rhs.usage : lhs.page < rhs.page
    }
}

struct RemoteDeviceDescriptor: Equatable {
    let id: String
    let name: String
    let serial: String?
    let vendorID: Int
    let productID: Int
    let transport: String

    init(
        id: String,
        name: String,
        serial: String?,
        vendorID: Int = 0,
        productID: Int = 0,
        transport: String = "Bluetooth"
    ) {
        self.id = id
        self.name = name
        self.serial = serial
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
    }

    var isKnownXiaomiRemote: Bool {
        vendorID == 10_007 && productID == 12_984
    }

    var isC2LiteRemote: Bool {
        id.hasPrefix("ble-c2:")
    }

    var isBLEGATTRemote: Bool {
        id.hasPrefix("ble-c2:") || id.hasPrefix("ble-gatt:")
    }

    var selectionLabel: String {
        let suffix = id.suffix(6)
        return "\(name) · \(suffix)"
    }
}

struct RemoteProfile: Codable, Equatable {
    let deviceID: String
    var deviceName: String
    var vendorID: Int?
    var productID: Int?
    var mappings: [KeyMapping]

    var isKnownXiaomiRemote: Bool {
        vendorID == 10_007 && productID == 12_984
    }

    var isC2LiteRemote: Bool {
        deviceID.hasPrefix("ble-c2:")
    }
}

enum RemoteAction: String, Codable, CaseIterable {
    case passThrough = "passThrough"
    case tab = "tab"
    case escape = "escape"
    case pageUp = "pageUp"
    case pageDown = "pageDown"
    case space = "space"
    case returnKey = "return"
    case missionControl = "missionControl"
    case showDesktop = "showDesktop"
    case spotlight = "spotlight"
    case playPause = "playPause"
    case mute = "mute"
    case delete = "delete"
    case fnModifier = "fn"
    case activateCodex = "activateCodex"
    case power = "power"
    case logOnly = "logOnly"

    static let remoteFirstBatch: [RemoteAction] = [
        .tab,
        .escape,
        .pageUp,
        .pageDown,
        .space,
        .returnKey,
        .missionControl,
        .showDesktop,
        .spotlight,
        .playPause,
        .mute
    ]

    var displayName: String {
        switch self {
        case .passThrough: return "保持原按键"
        case .tab: return "Tab"
        case .escape: return "Escape"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .space: return "Space / 空格"
        case .returnKey: return "Return / Enter（可能确认或发送）"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "显示桌面"
        case .spotlight: return "Spotlight"
        case .playPause: return "播放 / 暂停"
        case .mute: return "静音"
        case .delete: return "删除键"
        case .fnModifier: return "Fn 修饰键"
        case .activateCodex: return "Codex 前台并聚焦输入框"
        case .power: return "Power 原功能（系统事件重放）"
        case .logOnly: return "仅记录日志"
        }
    }
}

struct KeyMapping: Codable, Equatable {
    let usage: HIDUsage
    var action: RemoteAction
    var keyName: String

    var sourceCodeName: String {
        switch (usage.page, usage.usage) {
        case (0xFF00, _): return "BLE"
        case (7, 241): return "特殊键"
        case (7, 62): return "F5"
        case (7, 74): return "Home"
        case (7, 101): return "Application"
        case (7, 53): return "` / ~"
        case (7, 102): return "Power"
        default: return "HID"
        }
    }

    var technicalDescription: String {
        "\(sourceCodeName) · \(usage)"
    }

    var recentKeyDescription: String {
        "\(keyName)（\(sourceCodeName)）→ \(action.displayName)"
    }

    static func learnedName(for usage: HIDUsage) -> String {
        if let known = AppConfiguration.defaultMappings.first(where: { $0.usage == usage }) {
            return known.keyName
        }
        return "自定义按键 \(usage)"
    }
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 7

    var schemaVersion: Int? = currentSchemaVersion
    var boundSerial: String?
    var selectedDeviceID: String?
    var selectedDeviceName: String?
    var mappings: [KeyMapping]
    var deviceProfiles: [RemoteProfile]?

    static let defaultMappings: [KeyMapping] = [
        KeyMapping(usage: HIDUsage(page: 7, usage: 241), action: .delete, keyName: "返回键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 62), action: .fnModifier, keyName: "语音键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 74), action: .passThrough, keyName: "主页键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 101), action: .activateCodex, keyName: "菜单键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 53), action: .passThrough, keyName: "直播键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 102), action: .power, keyName: "电源键")
    ]

    // C2-RC-LITE is a BLE GATT remote rather than a HID keyboard.  Its
    // notification byte is stored in a vendor page so the existing learning
    // and per-device mapping UI can treat it just like any other input.
    static let c2LiteDefaultMappings: [KeyMapping] = [
        KeyMapping(usage: HIDUsage(page: 0xFF00, usage: 0x50), action: .logOnly, keyName: "左键"),
        KeyMapping(usage: HIDUsage(page: 0xFF00, usage: 0x4F), action: .logOnly, keyName: "右键"),
        KeyMapping(usage: HIDUsage(page: 0xFF00, usage: 0x52), action: .delete, keyName: "返回键"),
        KeyMapping(usage: HIDUsage(page: 0xFF00, usage: 0x51), action: .activateCodex, keyName: "菜单键"),
        KeyMapping(usage: HIDUsage(page: 0xFF00, usage: 0x28), action: .fnModifier, keyName: "语音键")
    ]

    static let defaults = AppConfiguration(
        schemaVersion: currentSchemaVersion,
        boundSerial: nil,
        selectedDeviceID: nil,
        selectedDeviceName: nil,
        mappings: defaultMappings,
        deviceProfiles: []
    )

    func action(for usage: HIDUsage) -> RemoteAction? {
        mappings.first(where: { $0.usage == usage })?.action
    }
}

enum ConnectionState: Equatable {
    case stopped
    case waiting(selectedDeviceName: String?)
    case connected(product: String, serial: String?)
    case failed(String)

    var displayName: String {
        switch self {
        case .stopped: return "已停止"
        case let .waiting(selectedDeviceName):
            if let selectedDeviceName, !selectedDeviceName.isEmpty {
                return "已选择：\(selectedDeviceName)（当前离线，等待自动重连）"
            }
            return "尚未选择遥控器"
        case let .connected(product, _): return "已连接：\(product)"
        case let .failed(message): return "连接失败：\(message)"
        }
    }
}
