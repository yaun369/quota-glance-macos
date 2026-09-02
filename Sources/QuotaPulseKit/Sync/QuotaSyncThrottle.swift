import Foundation

/// Decides whether a freshly-fetched snapshot is worth pushing to CloudKit.
/// Pure and side-effect free so it can be unit tested without a network or
/// an iCloud account. Per the plan: don't upload on every poll, only when
/// something a viewer would actually notice has changed.
public enum QuotaSyncThrottle {
    public static func shouldSync(
        previous: QuotaSnapshot?,
        next: QuotaSnapshot,
        lastSyncedAt: Date?,
        now: Date = Date(),
        thresholds: QuotaThresholds = .default,
        minimumInterval: TimeInterval = 300,
        percentDelta: Double = 1
    ) -> Bool {
        guard let previous else { return true }
        guard lastSyncedAt != nil else { return true }

        if percentChanged(previous.session.usedPercent, next.session.usedPercent, by: percentDelta) { return true }
        if percentChanged(previous.weekly.usedPercent, next.weekly.usedPercent, by: percentDelta) { return true }
        if previous.session.resetAt != next.session.resetAt { return true }
        if previous.weekly.resetAt != next.weekly.resetAt { return true }
        if crossedThreshold(previous.session.remainingPercent, next.session.remainingPercent, thresholds: thresholds) { return true }
        if crossedThreshold(previous.weekly.remainingPercent, next.weekly.remainingPercent, thresholds: thresholds) { return true }
        if let lastSyncedAt, now.timeIntervalSince(lastSyncedAt) >= minimumInterval { return true }

        return false
    }

    private static func percentChanged(_ before: Double?, _ after: Double?, by delta: Double) -> Bool {
        switch (before, after) {
        case (nil, nil): return false
        case (nil, .some), (.some, nil): return true
        case let (before?, after?): return abs(before - after) >= delta
        }
    }

    private static func crossedThreshold(_ before: Double?, _ after: Double?, thresholds: QuotaThresholds) -> Bool {
        guard let before, let after, after < before else { return false }
        let levels = [thresholds.urgentRemainingPercent, thresholds.importantRemainingPercent, thresholds.lightRemainingPercent]
        return levels.contains { before >= $0 && after < $0 }
    }
}
