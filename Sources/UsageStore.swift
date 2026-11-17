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

struct UsageWindow: Codable, Hashable, Identifiable, Sendable {
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

    static func readLocalWork() -> [QuotaWorkTask]? {
        let directory = fileURL.deletingLastPathComponent().appending(path: "active-work")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return nil }

        let now = Date().timeIntervalSince1970
        let decoder = JSONDecoder()
        let events = files.compactMap { file -> LocalWorkEvent? in
            guard file.lastPathComponent.range(of: #"^[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil,
                  let attributes = try? file.resourceValues(forKeys: keys),
                  attributes.isRegularFile == true, attributes.isSymbolicLink == false,
                  let size = attributes.fileSize, size <= 8_192,
                  let data = try? Data(contentsOf: file),
                  let event = try? decoder.decode(LocalWorkEvent.self, from: data),
                  (0...600).contains(now - event.lastSeen) else { return nil }
            return event
        }
        return events.sorted { $0.lastSeen > $1.lastSeen }.map(\.task)
    }

    private struct LocalWorkEvent: Decodable {
        let lastSeen: TimeInterval
        let title: String
        let status: String
        let completedSteps: Int?
        let totalSteps: Int?
        let currentStep: String?
        let completedToolCalls: Int?
        let startedAt: TimeInterval?

        var task: QuotaWorkTask {
            let start = startedAt.flatMap { time in
                time > 0 && time <= lastSeen ? Date(timeIntervalSince1970: time) : nil
            }
            return QuotaWorkTask(
                title: String(title.prefix(100)),
                status: String(status.prefix(40)),
                completedSteps: completedSteps,
                totalSteps: totalSteps,
                currentStep: currentStep.map { String($0.prefix(100)) },
                completedToolCalls: completedToolCalls,
                startedAt: start
            )
        }
    }
}
