#if QUOTA_LIVE_ACTIVITY
import ActivityKit
import SwiftUI
import WidgetKit

@available(macOS 27.3, *)
struct QuotaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaActivityAttributes.self) { context in
            let display = QuotaActivityDisplay(state: context.state, isStale: context.isStale)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    display.heading
                    Spacer(minLength: 8)
                    display.syncStatus
                }
                display.expandedDetails
            }
            .padding()
        } dynamicIsland: { context in
            let display = QuotaActivityDisplay(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    display.heading
                }
                DynamicIslandExpandedRegion(.trailing) {
                    display.syncStatus
                }
                DynamicIslandExpandedRegion(.bottom) {
                    display.expandedDetails
                }
            } compactLeading: {
                CompactQuotaRegion(regular: display.compactHeading, limited: display.splitRing)
            } compactTrailing: {
                CompactQuotaRegion(regular: display.compactAllowances, limited: EmptyView())
            } minimal: {
                display.splitRing
            }
        }
    }
}

@available(macOS 27.3, *)
private struct CompactQuotaRegion<Regular: View, Limited: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited

    let regular: Regular
    let limited: Limited

    var body: some View {
        if isLimited {
            limited
        } else {
            regular
        }
    }
}

@available(macOS 27.3, *)
private struct QuotaActivityDisplay {
    let state: QuotaActivityAttributes.ContentState
    let isStale: Bool

    private var weekly: UsageWindow? { state.windows.first { $0.minutes == 10_080 } }
    private var fiveHour: UsageWindow? { state.windows.first { $0.minutes == 300 } }
    private var activeTasks: [QuotaWorkTask] { state.work?.tasks ?? [] }

    private var windows: [UsageWindow] {
        let typical = [weekly, fiveHour].compactMap { $0 }
        let other = state.windows.filter { window in
            !typical.contains(where: { $0.id == window.id })
        }
        return Array((typical + other).prefix(2))
    }

    private static let timestampStyle = Date.FormatStyle.dateTime
        .month(.defaultDigits).day(.defaultDigits)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))

    private var headingLabel: String {
        state.shared ? "Codex 与 ChatGPT Work 共享额度" : "Codex 额度"
    }

    var splitRing: some View {
        let values = [
            weekly.map { "左侧 7 天剩余 \($0.remainingPercent)%" } ?? "左侧 7 天额度未提供",
            fiveHour.map { "右侧 5 小时剩余 \($0.remainingPercent)%" } ?? "右侧 5 小时额度未提供"
        ]
        return SplitQuotaRing(
            weekly: weekly.map(remainingFraction),
            fiveHour: fiveHour.map(remainingFraction),
            isStale: isStale,
            hasActivity: state.activeTaskCount > 0
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headingLabel)
        .accessibilityValue(
            (values + (isStale ? ["额度待同步"] : []) + activityAnnouncement).joined(separator: "，")
        )
    }

    var compactHeading: some View {
        ViewThatFits(in: .horizontal) {
            if state.activeTaskCount > 0 {
                Label(state.activeTaskCount.formatted(), systemImage: "list.bullet")
                    .monospacedDigit()
                Image(systemName: "list.bullet")
            }
            Text("Codex")
            Image(systemName: "chart.bar")
        }
        .font(.footnote.weight(.semibold))
        .accessibilityLabel(headingLabel)
        .accessibilityValue(activityAnnouncement.joined(separator: "，"))
    }

    var heading: some View {
        ViewThatFits(in: .horizontal) {
            Text(state.shared ? "Codex + ChatGPT Work" : "Codex 额度")
            Text(state.shared ? "Codex + Work" : "Codex")
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .accessibilityLabel(headingLabel)
        .accessibilityAddTraits(.isHeader)
    }

    var syncStatus: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isStale {
                Text("数据待同步").fontWeight(.semibold)
            }
            ViewThatFits(in: .horizontal) {
                Text("同步于 \(state.fetchedAt.formatted(Self.timestampStyle))")
                Text("同步于 \(Text(state.fetchedAt, style: .time))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    var compactAllowances: some View {
        ViewThatFits(in: .horizontal) {
            if !isStale, let weekly, let fiveHour {
                HStack(spacing: 6) {
                    ForEach([weekly, fiveHour]) { window in
                        Text("\(periodTitle(window)) \(window.remainingPercent)%")
                            .accessibilityLabel("\(periodTitle(window))剩余 \(window.remainingPercent)%")
                    }
                }
            }
            splitRing
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
    }

    var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            allowances
            if let task = activeTasks.first {
                Divider()
                ViewThatFits(in: .vertical) {
                    if let second = activeTasks.dropFirst().first {
                        VStack(alignment: .leading, spacing: 5) {
                            workDetails(task)
                            taskHeading(second)
                                .lineLimit(1)
                                .accessibilityElement(children: .combine)
                        }
                    }
                    workDetails(task)
                }
            } else if state.activeTaskCount > 0 {
                Text("\(state.activeTaskCount) 项活动任务")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityAnnouncement: [String] {
        guard state.activeTaskCount > 0 else { return [] }
        let count = "\(state.activeTaskCount) 项活动任务"
        return [count] + (activeTasks.first.map { [$0.status] } ?? [])
    }

    private func taskHeading(_ task: QuotaWorkTask, showsCount: Bool = false) -> some View {
        let status = showsCount && state.activeTaskCount > 1
            ? "\(task.status) · \(state.activeTaskCount) 项任务"
            : task.status
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "list.bullet")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(task.title)
                .font(.caption.weight(.semibold))
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 2)
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func workDetails(_ task: QuotaWorkTask) -> some View {
        let plan = task.completedSteps.flatMap { completed in
            task.totalSteps.flatMap { total in
                total > 0 ? (completed: completed, total: total) : nil
            }
        }
        let toolCalls = plan == nil && task.currentStep == nil ? task.completedToolCalls : nil
        let startedAt = task.startedAt.flatMap { $0 <= Date.now ? $0 : nil }
        return VStack(alignment: .leading, spacing: 3) {
            taskHeading(task, showsCount: true)
            if task.currentStep != nil || plan != nil || toolCalls != nil || startedAt != nil {
                HStack(spacing: 6) {
                    if let plan {
                        Text("步骤 \(plan.completed)/\(plan.total)")
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("已完成 \(plan.completed) 步，共 \(plan.total) 步")
                    } else if let toolCalls {
                        Text("完成 \(toolCalls) 次工具调用")
                            .monospacedDigit()
                    }
                    if let currentStep = task.currentStep {
                        Text(currentStep)
                            .truncationMode(.tail)
                            .accessibilityLabel("当前步骤 \(currentStep)")
                    }
                    if let startedAt {
                        Spacer(minLength: 0)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .accessibilityHidden(true)
                                Text(startedAt, style: .timer)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("任务已用时 \(Text(startedAt, style: .timer))")
                            EmptyView()
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var allowances: some View {
        Group {
            if windows.isEmpty {
                Text("暂无额度数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(windows) { window in
                        allowance(window)
                    }
                }
            }
        }
    }

    private func periodTitle(_ window: UsageWindow) -> String {
        window.minutes == 10_080 ? "7 天" : window.title
    }

    private func remainingFraction(_ window: UsageWindow) -> Double {
        max(0, min(1, 1 - window.usedPercent / 100))
    }

    private func allowance(_ window: UsageWindow) -> some View {
        let used = min(100, max(0, window.usedPercent))
            .formatted(.number.precision(.fractionLength(0...1)))
        return VStack(alignment: .leading, spacing: 4) {
            Text(periodTitle(window))
                .font(.caption.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(window.remainingPercent)%")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("剩余 \(window.remainingPercent)%")
                Text("剩余")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            ProgressView(value: remainingFraction(window))
                .progressViewStyle(.linear)
                .tint(.primary)
                .accessibilityHidden(true)
            Text("已用 \(used)%")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Group {
                if let reset = window.resetsAt {
                    let time = reset.formatted(Self.timestampStyle)
                    Text("重置于 \(time)")
                        .accessibilityLabel("额度重置时间 \(time)")
                } else {
                    Text("重置时间未提供")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@available(macOS 27.3, *)
private struct SplitQuotaRing: View {
    let weekly: Double?
    let fiveHour: Double?
    let isStale: Bool
    let hasActivity: Bool

    private let diameter: CGFloat = 16
    private let lineWidth: CGFloat = 2
    private let start: CGFloat = 0.035
    private let end: CGFloat = 0.465

    var body: some View {
        ZStack {
            half(weekly)
                .scaleEffect(x: -1, y: 1)
            half(fiveHour)
            if isStale {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .bold))
            } else if hasActivity {
                Circle()
                    .fill(.primary)
                    .frame(width: 4, height: 4)
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }

    private func half(_ fraction: Double?) -> some View {
        ZStack {
            Circle()
                .trim(from: start, to: end)
                .stroke(
                    .primary.opacity(0.28),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: fraction == nil ? [1, 3] : [])
                )
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: start, to: start + (end - start) * CGFloat(fraction))
                    .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))
    }
}
#endif
