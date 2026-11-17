#if QUOTA_LIVE_ACTIVITY
import ActivityKit
import Foundation

@available(macOS 27.3, *)
struct QuotaActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let fetchedAt: Date
        let shared: Bool
        let windows: [UsageWindow]
        let activeTaskCount: Int
        let work: QuotaWorkProgress?

        init?(snapshot: UsageSnapshot?, work: QuotaWorkProgress?) {
            guard let snapshot,
                  let bucket = snapshot.buckets.first(where: { $0.id == "codex" }),
                  !bucket.windows.isEmpty else { return nil }
            self.fetchedAt = snapshot.fetchedAt
            self.shared = snapshot.shared
            self.windows = bucket.windows.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
            self.activeTaskCount = work?.tasks.count ?? 0
            self.work = work.map { progress in
                QuotaWorkProgress(tasks: Array(progress.tasks.prefix(2)), checkedAt: progress.checkedAt)
            }
        }
    }
}
#endif
