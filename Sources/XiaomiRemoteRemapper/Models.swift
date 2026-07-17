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
    case delete = "delete"
    case fnModifier = "fn"
    case showDesktop = "showDesktop"
    case activateCodex = "activateCodex"
    case spotlight = "spotlight"
    case power = "power"
    case logOnly = "logOnly"

    var displayName: String {
        switch self {
        case .passThrough: return "保持原按键"
        case .delete: return "删除键"
        case .fnModifier: return "Fn 修饰键"
        case .showDesktop: return "显示桌面"
        case .activateCodex: return "Codex 前台并聚焦输入框"
        case .spotlight: return "Spotlight"
        case .power: return "Power 原功能（系统事件重放）"
        case .logOnly: return "仅记录日志"
        }
    }
}

struct KeyMapping: Codable, Equatable {
    let usage: HIDUsage
    var action: RemoteAction
    let keyName: String
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int? = currentSchemaVersion
    var boundSerial: String?
    var mappings: [KeyMapping]

    static let defaultMappings: [KeyMapping] = [
        KeyMapping(usage: HIDUsage(page: 7, usage: 241), action: .delete, keyName: "usage 7:241"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 62), action: .fnModifier, keyName: "F5"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 74), action: .passThrough, keyName: "Home"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 101), action: .activateCodex, keyName: "Application"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 53), action: .passThrough, keyName: "` / ~"),
        KeyMapping(usage: HIDUsage(page: 7, usage: 102), action: .power, keyName: "Power")
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
