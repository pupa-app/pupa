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
            lastRefreshFailed = true
            return
        }
        harnesses = fetched
        models = Self.activeModels(in: fetched, harnessID: settings.activeHarnessID)
        lastRefreshFailed = false
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

    private static func activeModels(
        in harnesses: [HarnessDescriptor], harnessID: String?
    ) -> [KnownLLMModel] {
        let active: HarnessDescriptor? = {
            if let harnessID, let m = harnesses.first(where: { $0.id == harnessID }) { return m }
            return harnesses.first(where: { $0.isDefault }) ?? harnesses.first
        }()
        return active?.models ?? []
    }
}
