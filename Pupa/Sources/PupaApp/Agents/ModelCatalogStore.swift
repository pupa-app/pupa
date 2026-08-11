import Foundation
import Observation

/// Holds the backend's advertised agent harnesses (fetched from
/// `GET /harnesses`) and, for the active backend connection, the model list of
/// its selected harness.
///
/// There is **no** static fallback: when the backend is unreachable the model
/// list is empty and `lastRefreshFailed` is set, so the picker shows an
/// explicit "backend unreachable" state instead of presenting a stale hardcoded
/// catalog as if it were real.
///
/// Owned by `AppView`, refreshed on launch and every active-backend change.
@MainActor
@Observable
public final class ModelCatalogStore {
    /// Every harness the active backend advertises. Drives the harness picker
    /// and the per-harness tool/permission UI.
    public private(set) var harnesses: [HarnessDescriptor] = []
    /// Models of the active backend's selected harness. Empty until a
    /// successful refresh (no hardcoded fallback).
    public private(set) var models: [KnownLLMModel] = []
    /// Extended-thinking levels of the active harness (`[]` when the harness
    /// doesn't support thinking — the picker is then hidden).
    public private(set) var thinkingLevels: [ThinkingLevel] = []
    /// True while a `refresh` is in flight — lets the picker show a spinner.
    public private(set) var isRefreshing = false
    /// True when the most recent `refresh` couldn't reach the backend. The
    /// picker surfaces this instead of showing stale/fake models.
    public private(set) var lastRefreshFailed = false

    public func refresh(settings: SettingsStore) async {
        let client = BackendHarnessesClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        isRefreshing = true
        defer { isRefreshing = false }
        guard let fetched = try? await client.list(), !fetched.isEmpty else {
            // Unreachable / old backend / not paired → no fallback catalog.
            harnesses = []
            models = []
            thinkingLevels = []
            lastRefreshFailed = true
            return
        }
        harnesses = fetched
        let active = Self.activeHarness(in: fetched, harnessID: settings.activeHarnessID)
        models = active?.models ?? []
        thinkingLevels = active?.thinking ?? []
        lastRefreshFailed = false
    }

    /// Drop per-agent thinking overrides the active harness no longer advertises.
    /// Call right after a successful `refresh` (launch / backend switch). Guarded
    /// on a NON-EMPTY level set: when the harness advertises no thinking (or the
    /// backend is unreachable → `thinkingLevels` empty) this is a no-op, so a
    /// transient outage never wipes a still-valid override. Keeps the picker
    /// display ("Default" for an unadvertised level) and the send path in sync.
    public func reconcileThinking(store: MyAppStore, settings: SettingsStore) {
        guard !thinkingLevels.isEmpty else { return }
        let valid = Set(thinkingLevels.map(\.level))
        store.clearThinkingLevels(notIn: valid)
        if let level = settings.orchestratorThinking, !valid.contains(level) {
            settings.setOrchestratorThinking(nil)
        }
    }

    /// The descriptor for a harness id (nil → the backend's default harness).
    public func harness(id: String?) -> HarnessDescriptor? {
        if let id, let match = harnesses.first(where: { $0.id == id }) { return match }
        return harnesses.first(where: { $0.isDefault }) ?? harnesses.first
    }

    public func model(forId id: String) -> KnownLLMModel? {
        models.first(where: { $0.id == id })
    }

    public func model(provider: String, modelId: String) -> KnownLLMModel? {
        models.first(where: { $0.provider == provider && $0.modelId == modelId })
    }

    private static func activeHarness(
        in harnesses: [HarnessDescriptor], harnessID: String?
    ) -> HarnessDescriptor? {
        if let harnessID, let m = harnesses.first(where: { $0.id == harnessID }) { return m }
        return harnesses.first(where: { $0.isDefault }) ?? harnesses.first
    }
}
