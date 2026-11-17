import Foundation
import OSLog

struct UsageSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var shared: Bool
    var buckets: [UsageBucket]
}

struct UsageBucket: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var windows: [UsageWindow]
}

struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var minutes: Int?
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Int {
        Int(max(0, min(100, 100 - usedPercent)).rounded(.down))
    }

    var title: String {
        switch minutes {
        case 300: "5 小时"
        case 1_440: "每日"
        case 10_080: "每周"
        case let duration? where duration > 0 && duration % 1_440 == 0:
            "\(duration / 1_440) 天"
        case let duration? where duration > 0 && duration % 60 == 0:
            "\(duration / 60) 小时"
        case let duration? where duration > 0: "\(duration) 分钟"
        default: id == "secondary" ? "次要时段" : "主要时段"
        }
    }
}

enum UsageStore {
    static let widgetKind = "local.openai.usage.desktop"
    static let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let refreshInterval: TimeInterval = 15 * 60
    private static let logger = Logger(subsystem: "local.openai.usage", category: "cache")

    private static var fileURL: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "QuotaCachePath") as? String {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectory(forUser: NSUserName()) ??
            FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: "Library/Application Support/Local OpenAI Usage/usage.json")
    }

    static func read() -> UsageSnapshot? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            let failure = error as NSError
            logger.debug("Could not read the quota cache: \(failure.domain, privacy: .public) \(failure.code)")
            return nil
        }
    }

    static func write(_ snapshot: UsageSnapshot) throws {
        let file = fileURL
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}
