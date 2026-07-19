import Foundation

struct HIDUsage: Hashable, Codable, Comparable, CustomStringConvertible {
    let page: UInt32
    let usage: UInt32

    var description: String { "\(page):\(usage)" }

    static func < (lhs: HIDUsage, rhs: HIDUsage) -> Bool {
        lhs.page == rhs.page ? lhs.usage < rhs.usage : lhs.page < rhs.page
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
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int? = currentSchemaVersion
    var boundSerial: String?
    var mappings: [KeyMapping]

    static let defaultMappings: [KeyMapping] = [
        KeyMapping(usage: HIDUsage(page: 7, usage: 241), action: .delete, keyName: "返回键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 62), action: .fnModifier, keyName: "语音键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 74), action: .passThrough, keyName: "主页键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 101), action: .activateCodex, keyName: "菜单键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 53), action: .passThrough, keyName: "直播键"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 102), action: .power, keyName: "电源键")
    ]

    static let defaults = AppConfiguration(
        schemaVersion: currentSchemaVersion,
        boundSerial: nil,
        mappings: defaultMappings
    )

    func action(for usage: HIDUsage) -> RemoteAction? {
        mappings.first(where: { $0.usage == usage })?.action
    }
}

enum ConnectionState: Equatable {
    case stopped
    case waiting
    case connected(product: String, serial: String?)
    case failed(String)

    var displayName: String {
        switch self {
        case .stopped: return "已停止"
        case .waiting: return "等待遥控器连接"
        case let .connected(product, _): return "已连接：\(product)"
        case let .failed(message): return "连接失败：\(message)"
        }
    }
}
