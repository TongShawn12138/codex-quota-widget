import Darwin
import Foundation

enum CodexClient {
    static func read() throws -> UsageSnapshot {
        let executable = try cliExecutable()
        return try read(
            from: executable,
            arguments: ["app-server", "--stdio", "-c", "analytics.enabled=false"]
        )
    }

    static func readWorkProgress() -> QuotaWorkProgress? {
        let cloud = try? readCloudWork()
        let local = UsageStore.readLocalWork()
        guard local != nil || cloud != nil else { return nil }
        return QuotaWorkProgress(tasks: (local ?? []) + (cloud ?? []), checkedAt: Date())
    }

    private static func readCloudWork() throws -> [QuotaWorkTask] {
        let executable = try cliExecutable()
        let files = FileManager.default
        let workingDirectory = files.temporaryDirectory.appending(path: "quota-cloud-\(UUID().uuidString)")
        // The experimental cloud command writes diagnostics to its working directory.
        try files.createDirectory(at: workingDirectory, withIntermediateDirectories: false, attributes: [
            .posixPermissions: 0o700
        ])
        defer { try? files.removeItem(at: workingDirectory) }
        return try withProcess(
            from: executable,
            arguments: ["cloud", "list", "--json", "--limit", "20", "-c", "analytics.enabled=false"],
            workingDirectory: workingDirectory
        ) { writer, responses in
            try writer.close()
            let tasks: CloudTasks = try responses.readJSON(within: 8)
            return tasks.pendingTasks
        }
    }

    private static func cliExecutable() throws -> URL {
        let bundledCLI = "Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/" + bundledCLI,
            home.appending(path: bundledCLI).path,
            home.appending(path: ".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let cli = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ClientError.cliUnavailable
        }

        return URL(fileURLWithPath: cli)
    }

    private static func read(from executable: URL, arguments: [String]) throws -> UsageSnapshot {
        try appServer(from: executable, arguments: arguments) { writer, responses in
            try send(["method": "account/rateLimits/read", "id": 2], to: writer)
            let limits: RateLimits = try responses.wait(for: 2, within: 10)
            return UsageSnapshot(fetchedAt: Date(), shared: true, buckets: limits.validBuckets)
        }
    }

    private static func appServer<Result>(
        from executable: URL,
        arguments: [String],
        _ request: (FileHandle, inout Responses) throws -> Result
    ) throws -> Result {
        try withProcess(from: executable, arguments: arguments) { writer, responses in
            try send([
                "method": "initialize",
                "id": 1,
                "params": ["clientInfo": ["name": "local_usage_widget", "version": "1.0"]]
            ], to: writer)
            let _: Empty = try responses.wait(for: 1, within: 3)
            try send(["method": "initialized", "params": [:]], to: writer)
            return try request(writer, &responses)
        }
    }

    private static func withProcess<Result>(
        from executable: URL,
        arguments: [String],
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        _ request: (FileHandle, inout Responses) throws -> Result
    ) throws -> Result {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClientError.connection
        }
        do {
            try process.run()
        } catch {
            throw ClientError.connection
        }
        defer {
            try? writer.close()
            try? reader.close()
            if process.isRunning {
                process.terminate()
            }
        }

        var responses = Responses(fileDescriptor: reader.fileDescriptor)
        return try request(writer, &responses)
    }

    private static func send(_ message: [String: Any], to writer: FileHandle) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(10)
        do {
            try writer.write(contentsOf: line)
        } catch {
            throw ClientError.connection
        }
    }

    private enum ClientError: LocalizedError {
        case cliUnavailable
        case connection
        case response
        case signInRequired
        case timeout

        var errorDescription: String? {
            switch self {
            case .cliUnavailable: "找不到 Codex 命令行。请确认 ChatGPT 桌面应用已安装。"
            case .connection: "无法连接本机的 Codex 服务。"
            case .response: "Codex 暂时无法提供额度，请稍后重试。"
            case .signInRequired: "请先在 Codex 命令行使用 ChatGPT 帐号登录。"
            case .timeout: "同步额度超时，请稍后重试。"
            }
        }
    }

    private struct Responses {
        let fileDescriptor: Int32
        private var buffer = Data()
        private let decoder = JSONDecoder()

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        mutating func wait<Result: Decodable>(for id: Int, within seconds: Double) throws -> Result {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                let line = try nextLine(before: deadline)
                guard let header = try? decoder.decode(ResponseHeader.self, from: line),
                      header.id == id, header.method == nil else { continue }
                if let message = header.error?.message.lowercased() {
                    let signInMessages = [
                        "requires chatgpt", "requires a chatgpt", "not authenticated", "not logged in", "unauthorized"
                    ]
                    throw signInMessages.contains(where: message.contains)
                        ? ClientError.signInRequired : ClientError.response
                }
                guard let response = try? decoder.decode(Response<Result>.self, from: line) else {
                    throw ClientError.response
                }
                return response.result
            }
            throw ClientError.timeout
        }

        mutating func readJSON<Result: Decodable>(within seconds: Double) throws -> Result {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while let chunk = try readChunk(before: deadline) {
                buffer.append(chunk)
                guard buffer.count <= 1_048_576 else { throw ClientError.response }
            }
            return try decoder.decode(Result.self, from: buffer)
        }

        private mutating func nextLine(before deadline: TimeInterval) throws -> Data {
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return line
                }
                guard buffer.count <= 1_048_576 else { throw ClientError.response }
                guard let chunk = try readChunk(before: deadline) else { throw ClientError.connection }
                buffer.append(chunk)
            }
        }

        private func readChunk(before deadline: TimeInterval) throws -> Data? {
            var chunk = [UInt8](repeating: 0, count: 8_192)
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ClientError.timeout }
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32((remaining * 1_000).rounded(.up)))
                if ready == 0 { throw ClientError.timeout }
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw ClientError.connection }

                let count = chunk.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw ClientError.connection }
                return count == 0 ? nil : Data(chunk.prefix(count))
            }
        }
    }

    private struct ResponseHeader: Decodable {
        struct Failure: Decodable {
            let message: String
        }

        let id: Int?
        let method: String?
        let error: Failure?
    }

    private struct Response<Result: Decodable>: Decodable {
        let result: Result
    }

    private struct Empty: Decodable {}

    private struct CloudTasks: Decodable {
        let tasks: [Task]

        var pendingTasks: [QuotaWorkTask] {
            tasks.compactMap { task in
                guard task.status?.lowercased() == "pending" else { return nil }
                let title = task.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return QuotaWorkTask(
                    title: title.isEmpty ? "Codex 云端任务" : String(title.prefix(100)),
                    status: "云端待完成",
                    completedSteps: nil,
                    totalSteps: nil,
                    currentStep: nil,
                    completedToolCalls: nil,
                    startedAt: nil
                )
            }
        }

        struct Task: Decodable {
            let title: String?
            let status: String?
        }
    }

    private struct RateLimits: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: KnownBuckets?

        var validBuckets: [UsageBucket] {
            let legacyID = rateLimits?.limitId ?? "codex"
            let legacyCodex = legacyID == "codex" ? rateLimits : nil
            guard let bucket = rateLimitsByLimitId?.codex ?? legacyCodex else { return [] }
            let windows = [
                bucket.primary?.usageWindow(id: "primary"),
                bucket.secondary?.usageWindow(id: "secondary")
            ].compactMap { $0 }
            guard !windows.isEmpty else { return [] }
            return [UsageBucket(id: "codex", name: "Codex", windows: windows)]
        }

        struct KnownBuckets: Decodable {
            let codex: Bucket?
        }

        struct Bucket: Decodable {
            let limitId: String?
            let primary: Window?
            let secondary: Window?
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Int?
            let resetsAt: TimeInterval?

            func usageWindow(id: String) -> UsageWindow? {
                guard let usedPercent, usedPercent.isFinite else { return nil }
                return UsageWindow(
                    id: id,
                    minutes: windowDurationMins,
                    usedPercent: min(100, max(0, usedPercent)),
                    resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }
}
