import AppKit
import CoreServices
import ServiceManagement
import SwiftUI
import WidgetKit

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot = UsageStore.read()
    @Published private(set) var isRefreshing = false
    @Published private(set) var syncError: String?
    @Published private(set) var loginError: String?
    @Published private(set) var loginStatus = SMAppService.mainApp.status
#if QUOTA_LIVE_ACTIVITY
    static let followsChatGPTKey = "ShowQuotaWhileChatGPTRuns"
    @Published var followsChatGPT = UserDefaults.standard.bool(forKey: followsChatGPTKey)
    @Published var isChatGPTRunning = false
    @Published var quotaActivityError: String?
    var isReconcilingQuotaActivity = false
    var quotaActivityDismissedForSession = false
    var observedQuotaActivityID: String?
    var quotaActivityObservation: Task<Void, Never>?
    var quotaWorkObservation: Task<Void, Never>?
    var quotaWorkProgress: QuotaWorkProgress?
#endif

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let updated = try await Task.detached(priority: .utility) {
                let updated = try CodexClient.read()
                try UsageStore.write(updated)
                return updated
            }.value
            let previous = snapshot
            snapshot = updated
            syncError = nil
            if previous?.buckets != updated.buckets || previous?.shared != updated.shared
                || updated.fetchedAt.timeIntervalSince(previous?.fetchedAt ?? .distantPast)
                    > 2 * UsageStore.refreshInterval {
                WidgetCenter.shared.reloadTimelines(ofKind: UsageStore.widgetKind)
            }
#if QUOTA_LIVE_ACTIVITY
            if #available(macOS 27.3, *) {
                if observedQuotaActivityID == nil {
                    await reconcileQuotaActivity()
                } else {
                    await updateQuotaActivity(using: updated)
                }
            }
#endif
        } catch {
            syncError = (error as? LocalizedError)?.errorDescription ?? "暂时无法同步额度。"
        }
    }

    func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: UsageStore.widgetKind)
    }

    func updateLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            loginError = nil
        } catch {
            loginError = "无法更改登录项。请在系统设置中查看。"
        }
        updateLoginStatus()
    }
}

private struct UsageOverview: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let snapshot = monitor.snapshot, !snapshot.buckets.isEmpty {
                    ForEach(snapshot.buckets) { bucket in
                        VStack(alignment: .leading, spacing: 10) {
                            if bucket.id != "codex" {
                                Text(bucket.name ?? bucket.id).font(.headline)
                            }
                            ForEach(bucket.windows) { window in
                                allowance(window)
                            }
                        }
                    }
                } else {
                    Text(monitor.isRefreshing ? "正在读取账号额度…" : "暂时没有可显示的额度")
                        .foregroundStyle(.secondary)
                }
                if let error = monitor.syncError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("普通 ChatGPT 聊天的独立余额未通过此接口提供。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monitor.snapshot?.shared == false ? "Codex 额度" : "Codex 与 ChatGPT Work")
                .font(.title2.weight(.semibold))
            if let fetchedAt = monitor.snapshot?.fetchedAt {
                Text("上次同步 \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func allowance(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).font(.headline)
                Spacer()
                Text("剩余 \(window.remainingPercent)%").monospacedDigit()
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .accessibilityLabel("\(window.title)剩余额度")
            if let resetsAt = window.resetsAt {
                Text(resetsAt > Date()
                    ? "重置于 \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
                    : "已到重置时间，等待同步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task {
                        await monitor.refresh()
                        monitor.reloadWidget()
                    }
                } label: {
                    Label("立即同步", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing)
                Link("打开官方用量页面", destination: UsageStore.dashboardURL)
            }
#if QUOTA_LIVE_ACTIVITY
            if #available(macOS 27.3, *) {
                Toggle("ChatGPT 运行时在灵动岛显示", isOn: Binding(
                    get: { monitor.followsChatGPT },
                    set: { monitor.setFollowsChatGPT($0) }
                ))
                if let error = monitor.quotaActivityError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                } else if monitor.followsChatGPT && !monitor.isChatGPTRunning {
                    Text("等待 ChatGPT 打开")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
#endif
            Toggle("登录后自动同步", isOn: Binding(
                get: { monitor.loginStatus == .enabled || monitor.loginStatus == .requiresApproval },
                set: { monitor.setLaunchAtLogin($0) }
            ))
            if monitor.loginStatus == .requiresApproval || monitor.loginError != nil {
                Button(monitor.loginError ?? "在系统设置中允许此登录项") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link)
            }
        }
    }
}

@main
@MainActor
final class UsageApp: NSObject, NSApplicationDelegate {
    private let monitor = UsageMonitor()
    private var window: NSWindow?
    private var timer: Timer?
#if QUOTA_LIVE_ACTIVITY
    private var chatGPTObservation: NSKeyValueObservation?
#endif

    static func main() {
        let app = NSApplication.shared
        let delegate = UsageApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if QUOTA_LIVE_ACTIVITY
        if #available(macOS 27.3, *) {
            chatGPTObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in self?.updateChatGPTPresence() }
            }
            updateChatGPTPresence(retry: true)
        }
#endif
        Task { await monitor.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.monitor.refresh() }
        }
        timer?.tolerance = 60
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let reason = launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        if reason != OSType(keyAELaunchedAsLogInItem) {
            showWindow()
        }
    }

    @objc private func didWake() {
#if QUOTA_LIVE_ACTIVITY
        if #available(macOS 27.3, *) {
            updateChatGPTPresence(retry: true)
        }
#endif
        let lastUpdate = monitor.snapshot?.fetchedAt ?? .distantPast
        if Date().timeIntervalSince(lastUpdate) >= UsageStore.refreshInterval {
            Task { await monitor.refresh() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        monitor.updateLoginStatus()
#if QUOTA_LIVE_ACTIVITY
        if #available(macOS 27.3, *) {
            updateChatGPTPresence(retry: true)
        }
#endif
    }

#if QUOTA_LIVE_ACTIVITY
    @available(macOS 27.3, *)
    private func updateChatGPTPresence(retry: Bool = false) {
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated else { return false }
            return app.bundleIdentifier == "com.openai.chat" ||
                (app.bundleIdentifier == "com.openai.codex" &&
                    app.bundleURL?.lastPathComponent == "ChatGPT.app")
        }
        if monitor.isChatGPTRunning != isRunning {
            monitor.quotaActivityDismissedForSession = false
            monitor.isChatGPTRunning = isRunning
        } else if !retry {
            return
        }
        Task { await monitor.reconcileQuotaActivity() }
    }
#endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if QUOTA_LIVE_ACTIVITY
        if #available(macOS 27.3, *) {
            chatGPTObservation?.invalidate()
            monitor.isChatGPTRunning = false
            Task {
                await monitor.endQuotaActivities()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
#endif
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "local-quota" && $0.host == "open" }) else { return }
        showWindow()
        Task { await monitor.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 390),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "用量额度"
            window.contentMinSize = NSSize(width: 370, height: 325)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UsageOverview(monitor: monitor))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
