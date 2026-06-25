import Foundation
import Observation

/// Holds the list of available LLM models, fetched from the backend's
/// `GET /models` endpoint. Falls back to `KnownLLMModelCatalog.all` when
/// the backend is unreachable (offline, old backend, not paired yet).
///
/// Owned by `AppView` and passed into `AgentDetailView` and `AgentRegistry`
/// so the model picker always reflects whatever the backend has registered.
@MainActor
@Observable
public final class ModelCatalogStore {
    public private(set) var models: [KnownLLMModel] = KnownLLMModelCatalog.all
    /// True while a `refresh` is in flight — lets the picker show a spinner.
    public private(set) var isRefreshing = false
    /// True when the most recent `refresh` couldn't reach the backend. The
    /// list still shows the last-known (or fallback) models, but the UI can
    /// surface that they may be stale instead of silently presenting the
    /// static fallback as if it were the backend's real catalog.
    public private(set) var lastRefreshFailed = false

    public func refresh(settings: SettingsStore) async {
        let client = BackendModelsClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        isRefreshing = true
        defer { isRefreshing = false }
        guard let fetched = try? await client.list(), !fetched.isEmpty else {
            lastRefreshFailed = true
            return
        }
        models = fetched
        lastRefreshFailed = false
    }

    public func model(forId id: String) -> KnownLLMModel? {
        models.first(where: { $0.id == id })
    }

    public func model(provider: String, modelId: String) -> KnownLLMModel? {
        models.first(where: { $0.provider == provider && $0.modelId == modelId })
    }
}
