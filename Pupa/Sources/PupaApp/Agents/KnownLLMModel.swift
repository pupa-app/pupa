import Foundation

/// One entry in the static catalog of LLM models a user can pick for an agent.
///
/// The `provider` + `modelId` pair is sent verbatim to the backend in
/// `forwardedProps["llm"]`; the backend's `MODEL_REGISTRY` resolves the
/// pair into a provider-specific id (e.g. Bedrock's `eu.anthropic.…`
/// inference profile prefix). Keeping the catalog static on both sides
/// avoids a `/models` discovery round-trip and keeps iOS ignorant of
/// provider-specific id formats.
public struct KnownLLMModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let modelId: String
    public let label: String

    public init(id: String, provider: String, modelId: String, label: String) {
        self.id = id
        self.provider = provider
        self.modelId = modelId
        self.label = label
    }
}

public enum KnownLLMProvider {
    public static let bedrock = "bedrock"
    public static let anthropic = "anthropic"
    public static let openaiCompatible = "openai_compatible"
}

public enum KnownLLMModelCatalog {
    /// Sentinel id used by the picker for "let the backend pick" — emitted when
    /// the user hasn't chosen a model for this agent and the backend default
    /// from `LLM_PROVIDER` / env applies. Sending no `llm` block in the request
    /// is equivalent — but having an explicit picker entry makes the default
    /// observable to the user.
    public static let backendDefaultId = "__backend_default__"

    /// Sentinel `thinking` level for "no override" — clears the per-agent
    /// thinking key so the backend applies its own default (adaptive). Distinct
    /// from the concrete levels the harness advertises (`auto`/`off`/…). Sending
    /// no `thinking` in the request is equivalent; the sentinel just makes the
    /// default observable/selectable in the picker.
    public static let thinkingDefaultId = "__thinking_default__"

    // No static model catalog: the live list comes from the backend's
    // `GET /harnesses` discovery (`ModelCatalogStore`). When the backend is
    // unreachable the picker shows an explicit empty/error state rather than a
    // hardcoded fallback that might not match what the backend can actually run.

    public static func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case KnownLLMProvider.bedrock: return "Bedrock"
        case KnownLLMProvider.anthropic: return "Anthropic"
        case KnownLLMProvider.openaiCompatible: return "OpenAI-compatible"
        default: return provider
        }
    }
}
