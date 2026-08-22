import Foundation
import Observation

/// In-memory cache of per-thread token + cost usage for the Agents dashboard.
///
/// Local to the overview (not app-wide): usage is only shown here, so it's
/// constructed from `SettingsStore` and refreshed on appear rather than
/// threaded through the coordinator. The backend already caches per thread
/// keyed by checkpoint fingerprint, so a refetch is cheap when nothing changed.
///
/// Advisory and lossy-tolerant: a missing entry, or one with `nil` totals,
/// simply renders no usage line. A failed refresh keeps the last values.
@MainActor
@Observable
public final class ThreadUsageStore {
    public private(set) var usage: [String: ThreadUsage] = [:]
    /// Prompt-cache breakdown, populated on demand (per-agent expand).
    public private(set) var cache: [String: ThreadCacheUsage] = [:]

    public init() {}

    /// Test seam: start from an explicit map.
    public init(seed: [String: ThreadUsage]) {
        usage = seed
    }

    /// Usage for `threadId`, or `nil` when unknown.
    public func usage(for threadId: String) -> ThreadUsage? {
        usage[threadId]
    }

    /// Aggregate cache-read % across `threadIds`, weighted by input tokens.
    /// Returns `nil` when no thread has a known breakdown.
    public func cacheReadPct(threadIds: [String]) -> Double? {
        var read = 0
        var total = 0
        for id in threadIds {
            guard let c = cache[id], let t = c.inputTotal else { continue }
            read += c.inputCacheRead ?? 0
            total += t
        }
        guard total > 0 else { return nil }
        return Double(read) / Double(total) * 100.0
    }

    /// Fetch cache breakdown for `threadIds` and merge. Swallows errors.
    public func refreshCache(threadIds: [String], client: BackendUsageClient) async {
        guard !threadIds.isEmpty else { return }
        do {
            let fetched = try await client.fetchCache(threadIds: threadIds)
            for (id, c) in fetched { cache[id] = c }
        } catch {
            // Advisory — keep last known values.
        }
    }

    /// Summed totals across `threadIds`. Returns `nil` when no thread has any
    /// known usage, so callers can hide the rollup entirely.
    public func rollup(threadIds: [String]) -> ThreadUsage? {
        var tokens = 0
        var cost = 0.0
        var any = false
        for id in threadIds {
            guard let u = usage[id] else { continue }
            if let t = u.totalTokens { tokens += t; any = true }
            if let c = u.costUSD { cost += c; any = true }
        }
        guard any else { return nil }
        return ThreadUsage(threadId: "", totalTokens: tokens, costUSD: cost)
    }

    /// Fetch usage for every id in one batched call and merge into the cache.
    /// Failures are swallowed — the dashboard degrades to whatever it had.
    public func refresh(threadIds: [String], client: BackendUsageClient) async {
        guard !threadIds.isEmpty else { return }
        do {
            let fetched = try await client.fetchUsage(threadIds: threadIds)
            for (id, u) in fetched { usage[id] = u }
        } catch {
            // Advisory data — keep last known values on any error.
        }
    }
}

// MARK: - Display formatting

/// Shared by the Agents roster and threads screens, which each own their own
/// store instance — one definition of how tokens and cost render.
extension ThreadUsageStore {
    /// One-line `"12.3k tok · $0.04"` for a thread, or `nil` when the backend
    /// reports no usage for it.
    public func line(for threadId: String) -> String? {
        usage(for: threadId).flatMap(Self.compose)
    }

    /// Same line, summed across `threadIds` — the MyApp-wide and per-agent
    /// aggregate captions.
    public func caption(threadIds: [String]) -> String? {
        rollup(threadIds: threadIds).flatMap(Self.compose)
    }

    private static func compose(_ u: ThreadUsage) -> String? {
        var parts: [String] = []
        if let tokens = u.totalTokens { parts.append(formatTokens(tokens) + " tok") }
        if let cost = u.costUSD { parts.append(formatCost(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func formatTokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        return String(format: "%.1fk", Double(tokens) / 1000.0)
    }

    public static func formatCost(_ cost: Double) -> String {
        // Sub-dollar costs need more precision than two decimals.
        cost < 1 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}
