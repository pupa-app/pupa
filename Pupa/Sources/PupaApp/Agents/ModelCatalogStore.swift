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

    public func refresh(settings: SettingsStore) async {
        let client = BackendModelsClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        guard let fetched = try? await client.list(), !fetched.isEmpty else { return }
        models = fetched
    }

    public func model(forId id: String) -> KnownLLMModel? {
        models.first(where: { $0.id == id })
    }

    public func model(provider: String, modelId: String) -> KnownLLMModel? {
        models.first(where: { $0.provider == provider && $0.modelId == modelId })
    }
}
