import SwiftUI
import WidgetKit

private struct UsageEntry: TimelineEntry {
    static let staleInterval: TimeInterval = 60 * 60

    let date: Date
    let usage: UsageSnapshot?
    var isExample = false

    var windows: [UsageWindow] {
        guard let bucket = usage?.buckets.first(where: { $0.id == "codex" }) else {
            return []
        }
        return bucket.windows.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
    }

    var isStale: Bool {
        guard let usage else { return false }
        return date.timeIntervalSince(usage.fetchedAt) >= Self.staleInterval
    }

    static var example: Self {
        let now = Date()
        let windows = [
            UsageWindow(id: "primary", minutes: 300, usedPercent: 24, resetsAt: now.addingTimeInterval(7_200)),
            UsageWindow(id: "secondary", minutes: 10_080, usedPercent: 42, resetsAt: now.addingTimeInterval(172_800))
        ]
        let usage = UsageSnapshot(
            fetchedAt: now,
            shared: true,
            buckets: [UsageBucket(id: "codex", name: "Codex", windows: windows)]
        )
        return Self(date: now, usage: usage, isExample: true)
    }
}

private struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .example
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? .example : UsageEntry(date: Date(), usage: UsageStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let reload = now.addingTimeInterval(30 * 60)
        let usage = UsageStore.read()
        let current = UsageEntry(date: now, usage: usage)
        let staleAfter = usage?.fetchedAt.addingTimeInterval(UsageEntry.staleInterval)
        let dates = (current.windows.map(\.resetsAt) + [staleAfter]).compactMap { $0 }
        let entries = Set(dates).sorted().reduce(into: [current]) { entries, date in
            guard let last = entries.last, date.timeIntervalSince(last.date) >= 5 * 60, date < reload else {
                return
            }
            entries.append(UsageEntry(date: date, usage: usage))
        }
        completion(Timeline(entries: entries, policy: .after(reload)))
    }
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: UsageEntry

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.windows.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                if isSmall {
                    compactWindows
                } else {
                    regularWindows
                }
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
        .widgetURL(URL(string: "local-quota://open"))
    }

    private var header: some View {
        let isShared = entry.usage?.shared == true
        let title = isShared ? (isSmall ? "Codex + Work" : "Codex + ChatGPT Work") : "Codex"

        return HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(renderingMode == .fullColor ? Color.accentColor : Color.primary)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityLabel(isShared ? "Codex 和 ChatGPT Work 共享额度" : "Codex 额度")
        .accessibilityAddTraits(.isHeader)
    }

    private var compactWindows: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entry.windows.prefix(2)) { window in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 3)
                        remaining(window, size: 16)
                    }
                    resetLabel(for: window)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var regularWindows: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(entry.windows.prefix(3)) { window in
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    remaining(window, size: 28)
                    ProgressView(value: Double(window.remainingPercent), total: 100)
                        .progressViewStyle(.linear)
                        .tint(renderingMode == .fullColor ? .accentColor : .primary)
                        .widgetAccentable()
                        .accessibilityHidden(true)
                    resetLabel(for: window)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func remaining(_ window: UsageWindow, size: CGFloat) -> some View {
        Text(window.remainingPercent.formatted() + "%")
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel("剩余 \(window.remainingPercent)%")
    }

    private func resetLabel(for window: UsageWindow) -> some View {
        let label: String
        if let reset = window.resetsAt {
            label = reset > entry.date ? "重置 \(shortDate(reset))" : "重置后待同步"
        } else {
            label = "重置时间未提供"
        }
        return Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var footer: some View {
        let label: String
        if entry.isExample {
            label = "示例 · 剩余额度"
        } else if entry.isStale {
            label = entry.usage.map { "待更新 · \(shortDate($0.fetchedAt))" } ?? "待更新"
        } else {
            label = entry.usage.map { "更新于 \(clockTime($0.fetchedAt))" } ?? ""
        }

        return Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.usage == nil ? "等待同步" : "暂无额度数据")
                .font(.system(size: 15, weight: .semibold))
            Text("点按查看同步状态")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }

    private func shortDate(_ date: Date) -> String {
        guard !Calendar.current.isDate(date, inSameDayAs: entry.date) else { return clockTime(date) }
        let day = date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).locale(Locale(identifier: "zh_CN")))
        return "\(day) \(clockTime(date))"
    }
}

@main
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UsageStore.widgetKind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("剩余额度")
        .description("查看 Codex 和 ChatGPT Work 的共享额度及重置时间。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
