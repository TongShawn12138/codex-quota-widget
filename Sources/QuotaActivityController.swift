#if QUOTA_LIVE_ACTIVITY
import ActivityKit
import Foundation
import OSLog

@available(macOS 27.3, *)
@MainActor
extension UsageMonitor {
    private var wantsQuotaActivity: Bool {
        followsChatGPT && isChatGPTRunning && !quotaActivityDismissedForSession
    }

    private var activeQuotaActivities: [Activity<QuotaActivityAttributes>] {
        Activity<QuotaActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    func setFollowsChatGPT(_ enabled: Bool) {
        followsChatGPT = enabled
        quotaActivityDismissedForSession = false
        UserDefaults.standard.set(enabled, forKey: Self.followsChatGPTKey)
        Task { await reconcileQuotaActivity() }
    }

    func reconcileQuotaActivity() async {
        guard !isReconcilingQuotaActivity else { return }
        isReconcilingQuotaActivity = true
        defer { isReconcilingQuotaActivity = false }

        if !wantsQuotaActivity {
            await endQuotaActivities()
            guard wantsQuotaActivity else { return }
        }

        if let activity = activeQuotaActivities.first {
            if observedQuotaActivityID != activity.id {
                watchQuotaActivity(activity)
            }
        } else {
            startQuotaActivity()
        }
    }

    func endQuotaActivities() async {
        if quotaActivityError != nil {
            quotaActivityError = nil
        }
        quotaWorkProgress = nil
        watchQuotaActivity(nil)
        for activity in activeQuotaActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func startQuotaActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            quotaActivityError = "请在系统设置中允许「用量额度」显示实时活动。"
            return
        }
        guard let state = QuotaActivityAttributes.ContentState(snapshot: snapshot, work: quotaWorkProgress) else {
            return
        }

        do {
            let activity = try Activity.request(
                attributes: QuotaActivityAttributes(),
                content: activityContent(for: state),
                pushType: nil
            )
            quotaActivityError = nil
            watchQuotaActivity(activity)
        } catch ActivityAuthorizationError.visibility {
            quotaActivityError = "请打开「用量额度」窗口以启动灵动岛活动。"
        } catch {
            Logger(subsystem: "local.openai.usage", category: "live-activity")
                .error("Could not start a quota activity: \(String(describing: error), privacy: .public)")
            quotaActivityError = "macOS 暂时无法启动额度实时活动。"
        }
    }

    func updateQuotaActivity(using snapshot: UsageSnapshot) async {
        guard wantsQuotaActivity, let activity = activeQuotaActivities.first,
              let state = QuotaActivityAttributes.ContentState(
                  snapshot: snapshot, work: quotaWorkProgress
              ) else { return }
        await activity.update(activityContent(for: state))
    }

    private func activityContent(
        for state: QuotaActivityAttributes.ContentState
    ) -> ActivityContent<QuotaActivityAttributes.ContentState> {
        let refreshDeadline = state.fetchedAt.addingTimeInterval(2 * UsageStore.refreshInterval)
        let nextReset = state.windows.compactMap(\.resetsAt).filter { $0 > state.fetchedAt }.min()
        return ActivityContent(state: state, staleDate: min(refreshDeadline, nextReset ?? refreshDeadline))
    }

    private func watchQuotaActivity(_ activity: Activity<QuotaActivityAttributes>?) {
        quotaActivityObservation?.cancel()
        quotaWorkObservation?.cancel()
        quotaActivityObservation = nil
        quotaWorkObservation = nil
        observedQuotaActivityID = activity?.id
        guard let activity else { return }
        quotaWorkObservation = Task { [weak self] in
            while !Task.isCancelled {
                let progress = await Task.detached(priority: .utility) {
                    CodexClient.readWorkProgress()
                }.value
                if Task.isCancelled { return }
                await self?.receiveWorkProgress(progress)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        quotaActivityObservation = Task { [weak self] in
            for await phase in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if phase == .ended || phase == .dismissed {
                    guard let self else { return }
                    self.quotaActivityDismissedForSession = phase == .dismissed
                    self.watchQuotaActivity(nil)
                    return
                }
            }
        }
    }

    private func receiveWorkProgress(_ progress: QuotaWorkProgress?) async {
        let changed = quotaWorkProgress?.tasks != progress?.tasks
        quotaWorkProgress = progress
        if changed, let snapshot {
            await updateQuotaActivity(using: snapshot)
        }
    }
}
#endif
