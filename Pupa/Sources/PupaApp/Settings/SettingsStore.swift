import Foundation
import Observation

/// One configured backend the iOS / macOS app can point at. Identity is a
/// random UUID so a backend's label or URL can change without breaking
/// references (active selection, paired-device-token map keyed off `id`).
///
/// `deviceID` is the server-side `device_id` returned by `POST /auth/pair` —
/// stored here so we can `DELETE /auth/devices/<id>` on unpair. The actual
/// device token never lives in this struct; it goes to the iOS Keychain via
/// `BackendCredentialStore`.
///
/// Auth shape: the only client-side credential is a paired-device token in
/// the Keychain. The pre-#163 `apiKey` field has been dropped — operators
/// who used to paste `PUPA_API_KEY` into Settings now run `make pair`
/// and pair instead. The server-side `PUPA_API_KEY` is still accepted
/// by the backend middleware but is server-side bootstrap only (used by
/// `make pair` to mint the first code) and is never exposed to clients.
public struct BackendEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var url: URL
    public var deviceID: UUID?
    /// SHA-256 fingerprint (hex) of the backend's self-signed TLS certificate.
    /// When set, the app pins the connection by fingerprint instead of relying
    /// on system trust — required for self-hosted HTTPS without a CA-signed cert.
    /// Populated automatically when pairing via QR (the QR encodes `fp=<hex>`).
    public var certFingerprint: String?
    /// Which backend agent harness this connection talks to (`deepagents`,
    /// `claude_code`, …). Chosen from the backend's `GET /harnesses` discovery.
    /// `nil` → the backend's default harness (talks to `POST /`, un-migrated).
    /// Drives the run endpoint (`/harnesses/{id}`) and which permission controls
    /// the Settings sheet shows.
    public var harnessID: String?

    public init(
        id: UUID = UUID(),
        label: String,
        url: URL,
        deviceID: UUID? = nil,
        certFingerprint: String? = nil,
        harnessID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.deviceID = deviceID
        self.certFingerprint = certFingerprint
        self.harnessID = harnessID
    }
}

/// Persistent user-controlled toggles surfaced in the Settings sheet.
///
/// Persistence is a JSON file `state/settings.json` under the active storage
/// root (iCloud container when available, else local) — see `PupaStorage`.
/// Device tokens are excluded: they stay in the Keychain, unsynced.
///
/// Stored:
///   - `disabledBackendTools` — which backend tools the user has muted; pushed
///     into every turn's `RunAgentInput.state` so the backend can drop them
///     from the model's tool list.
///   - `backends` — list of configured backends (URL + label + paired device id).
///     `activeBackendID` picks which one drives `backendURL` / `authHeaders`.
///     The previous single-URL schema (snapshot field `backendURL`) migrates
///     to a single-entry list on first load and keeps deserialising forever.
///     The pre-#163 `apiKey` snapshot field is silently dropped on read —
///     paired-device tokens have replaced it client-side.
@MainActor
@Observable
public final class SettingsStore {
    /// Legacy UserDefaults key. No longer the persistence backend (state moved
    /// to `state/settings.json`); retained only for onboarding's existing-user
    /// probe in `OnboardingMigration`.
    public static let storageKey = "pupa.settings.v1"

    // `nonisolated` so the off-main `load()` (pupa#110) can read these defaults.
    public nonisolated static let defaultBackendURL = URL(string: "http://localhost:8004/")!
    public nonisolated static let defaultBackendLabel = "Local backend"

    /// A2A (agent-to-agent) guardrails — see `AgentInvocationGate`.
    public nonisolated static let defaultA2AMaxChainDepth = 4
    public nonisolated static let defaultA2AMaxTurnsPerPair = 5
    /// UI bounds for the steppers; also clamp anything read from disk.
    public static let a2aMaxChainDepthRange = 1...8
    public static let a2aMaxTurnsPerPairRange = 1...20

    /// Per-turn tool-round cap (`AgentSession.maxRounds`). Every frontend-tool
    /// round-trip consumes one round, so multi-step turns need headroom; this
    /// is the client-side runaway breaker, not an A2A limit. It is **off by
    /// default** — a finite cap cut long agentic turns short, and the backend's
    /// own graph-step limit is the real runaway guard. This value is what the
    /// stepper starts from when the user switches the breaker back on.
    public nonisolated static let defaultMaxToolRounds = 24
    public static let maxToolRoundsRange = 4...64
    public nonisolated static let defaultToolRoundsUnlimited = true

    /// Per-MyApp cap on the bytes used by stored chat threads. When enabled,
    /// the oldest chats in a scope are auto-deleted once it exceeds this size.
    /// A stored thread is only metadata (its transcript lives on the backend),
    /// so the cap is fractional-MB and small on purpose. Decimal MB (× 1_000_000)
    /// to match the app's `ByteCountFormatter(.file)`.
    public nonisolated static let defaultThreadCapMB: Double = 5.0
    public static let threadCapMBRange: ClosedRange<Double> = 0.1...20

    public private(set) var disabledBackendTools: Set<String>
    /// Harness-specific permission-control values, keyed by harness id, then by
    /// the control `key` the backend advertised (e.g. `claude_loop_native`).
    /// The Deep Agents controls (`disabled_tools`, `shell_approval_disabled`) keep
    /// their dedicated fields above; this holds the *other* harnesses' controls
    /// (native scope, auto-approve, …) so tool/permission UI is per-harness.
    public private(set) var backendHarnessControls: [String: [String: HarnessSettingValue]]
    public private(set) var backends: [BackendEntry]
    public private(set) var activeBackendID: UUID
    /// User-controlled global override for the backend's `ShellApprovalMiddleware`.
    /// When `false` (default), the agent must ask before every shell command;
    /// flipping this on bypasses the approval card for the rest of the session
    /// (pushed into every turn's state as `shell_approval_disabled`).
    public private(set) var shellApprovalDisabled: Bool
    /// Per-orchestrator LLM selection. Stored as a global preference (the
    /// orchestrator has no MyApp parent). Both fields must be non-nil for
    /// the override to apply — either alone is treated as "no override" by
    /// the reader. The chat-level turn ships `forwardedProps["llm"]` for
    /// `.memory` scopes from this pair.
    public private(set) var orchestratorLLMProvider: String?
    public private(set) var orchestratorLLMModel: String?
    /// Per-orchestrator disabled tool names. Like the per-MyApp / per-Slack
    /// override, this is unioned with the global `disabledBackendTools` set on
    /// every `.memory`-scope turn — never an override. Stored globally (the
    /// orchestrator has no MyApp parent).
    public private(set) var orchestratorDisabledTools: Set<String>
    /// A2A guardrails surfaced in Settings → Agent-to-agent and fed into
    /// `AgentInvocationGate`. `a2aMaxTurnsPerPair` is the number of back-and-forth
    /// rounds one agent may have with another before the gate cuts it off;
    /// `a2aMaxChainDepth` caps how deep a chain of agents-calling-agents can go.
    public private(set) var a2aMaxChainDepth: Int
    public private(set) var a2aMaxTurnsPerPair: Int
    /// Max tool rounds per turn, fed into `AgentSession.setMaxRounds` on every
    /// send. A pending frontend-tool interrupt still gets its resume at the cap
    /// — the session drains instead of returning, which bounds (not removes)
    /// the stranded-backend window; this just bounds runaway tool loops.
    /// Applies on the next message. Ignored when `toolRoundsUnlimited` is on.
    public private(set) var maxToolRounds: Int
    /// When true (the default), turns run with NO tool-round cap
    /// (`AgentSession.maxRounds == nil`) — the client-side breaker is off and
    /// the backend's graph-step limit bounds the turn.
    public private(set) var toolRoundsUnlimited: Bool
    /// When true, each scope keeps only its most recent chats within
    /// `threadCapMB`; older chats are auto-deleted on new-chat and on settings
    /// change. Default off — opt-in, so an app update never silently deletes
    /// existing history.
    public private(set) var threadCapEnabled: Bool
    /// Per-scope chat-storage cap in MB (fractional). Applies only when
    /// `threadCapEnabled`. Clamped to `threadCapMBRange` and rounded to one
    /// decimal on write.
    public private(set) var threadCapMB: Double

    /// The cap actually handed to `AgentSession`: `nil` (no limit) when the
    /// breaker is off, else `maxToolRounds`.
    public var effectiveMaxToolRounds: Int? {
        toolRoundsUnlimited ? nil : maxToolRounds
    }

    /// The cap handed to `MyAppStore` for chat eviction: `nil` (no cap) when
    /// disabled, else `threadCapMB` converted to bytes.
    public var effectiveThreadCapBytes: Int? {
        threadCapEnabled ? Int((threadCapMB * 1_000_000).rounded()) : nil
    }

    /// Where paired-device tokens live. Keychain in production, swapped to
    /// `InMemoryCredentialStore` by tests so unit tests don't touch the real
    /// keychain. Not `@Observable` because credential changes don't drive UI
    /// directly — the row's badge re-evaluates whenever `backends` mutates,
    /// which is the same trigger that runs alongside `markPaired`.
    @ObservationIgnored
    public let credentials: any BackendCredentialStore

    /// The currently selected backend. Always present — `backends` is enforced
    /// non-empty; `activeBackendID` is always one of the entries.
    public var activeBackend: BackendEntry {
        backends.first(where: { $0.id == activeBackendID }) ?? backends[0]
    }

    /// URL of the active backend. Computed — every REST client
    /// (`BackendHarnessesClient`, `ScreenShareSignalingClient`, …) reads this as
    /// the FastAPI base and appends its own path.
    public var backendURL: URL { activeBackend.url }

    /// The AG-UI run endpoint for the active backend. When a harness is
    /// selected it is `{url}/harnesses/{harnessID}`; otherwise the bare `url`
    /// (the backend's default harness, mounted at `POST /`). This — not
    /// `backendURL` — is what `AgentClient` posts turns to.
    public var agentRunURL: URL {
        guard let harnessID = activeBackend.harnessID, !harnessID.isEmpty else {
            return activeBackend.url
        }
        return activeBackend.url
            .appendingPathComponent("harnesses")
            .appendingPathComponent(harnessID)
    }

    /// The active backend's selected harness id (`nil` → backend default).
    public var activeHarnessID: String? { activeBackend.harnessID }

    /// Returns a URLSession appropriate for the active backend.
    /// When the backend has a `certFingerprint` (self-signed TLS via `make setup`),
    /// the session pins by SHA-256 fingerprint instead of system trust.
    public var backendSession: URLSession {
        URLSession.forBackend(certFingerprint: activeBackend.certFingerprint)
    }

    /// Returns a URLSession appropriate for an arbitrary backend entry.
    public func session(for entry: BackendEntry) -> URLSession {
        URLSession.forBackend(certFingerprint: entry.certFingerprint)
    }

    public init(
        disabledBackendTools: Set<String>? = nil,
        backendURL: URL? = nil,
        shellApprovalDisabled: Bool? = nil,
        credentials: (any BackendCredentialStore)? = nil
    ) {
        let snapshot = Self.load()
        self.disabledBackendTools = disabledBackendTools ?? snapshot.disabledTools
        self.backendHarnessControls = snapshot.backendHarnessControls
        self.backends = snapshot.backends
        self.activeBackendID = snapshot.activeBackendID
        self.shellApprovalDisabled = shellApprovalDisabled ?? snapshot.shellApprovalDisabled
        self.orchestratorLLMProvider = snapshot.orchestratorLLMProvider
        self.orchestratorLLMModel = snapshot.orchestratorLLMModel
        self.orchestratorDisabledTools = snapshot.orchestratorDisabledTools
        self.a2aMaxChainDepth = snapshot.a2aMaxChainDepth
        self.a2aMaxTurnsPerPair = snapshot.a2aMaxTurnsPerPair
        self.maxToolRounds = snapshot.maxToolRounds
        self.toolRoundsUnlimited = snapshot.toolRoundsUnlimited
        self.threadCapEnabled = snapshot.threadCapEnabled
        self.threadCapMB = snapshot.threadCapMB
        self.credentials = credentials ?? KeychainCredentialStore()

        // Init override (tests + previews) edits the *active* backend's URL.
        if let backendURL {
            mutateActive { $0.url = backendURL }
        }
    }

    // MARK: - Tool toggles

    public func isEnabled(_ toolName: String) -> Bool {
        !disabledBackendTools.contains(toolName)
    }

    public func setEnabled(_ toolName: String, to enabled: Bool) {
        if enabled {
            guard disabledBackendTools.contains(toolName) else { return }
            disabledBackendTools.remove(toolName)
        } else {
            guard !disabledBackendTools.contains(toolName) else { return }
            disabledBackendTools.insert(toolName)
        }
        persist()
    }

    // MARK: - Backend list

    /// Edit the active backend's URL — preserves the old single-URL API for
    /// callers that don't know about the multi-backend list.
    public func setBackendURL(_ url: URL) {
        guard url != backendURL else { return }
        mutateActive { $0.url = url }
        persist()
    }

    /// Append a new backend. Returns the new entry's id so callers can flip
    /// the active selection or open an edit sheet on the row.
    @discardableResult
    public func addBackend(label: String, url: URL) -> UUID {
        let entry = BackendEntry(label: label, url: url)
        backends.append(entry)
        persist()
        return entry.id
    }

    /// Append a fully-formed entry (preserving its id so an edit sheet opened on
    /// it can pair immediately). No-op if the id is already present.
    public func addBackend(_ entry: BackendEntry) {
        guard !backends.contains(where: { $0.id == entry.id }) else { return }
        backends.append(entry)
        persist()
    }

    /// A throwaway display name for a backend the user didn't name — so pairing
    /// never blocks on a required label. e.g. "Backend a1b2".
    public static func randomBackendLabel() -> String {
        "Backend " + UUID().uuidString.prefix(4).lowercased()
    }

    /// Edit a backend in place. No-op if `id` is unknown.
    public func updateBackend(
        _ id: UUID,
        label: String? = nil,
        url: URL? = nil,
        deviceID: UUID?? = nil,
        certFingerprint: String?? = nil,
        harnessID: String?? = nil
    ) {
        guard let idx = backends.firstIndex(where: { $0.id == id }) else { return }
        if let label { backends[idx].label = label }
        if let url { backends[idx].url = url }
        if let deviceID { backends[idx].deviceID = deviceID }
        if let certFingerprint { backends[idx].certFingerprint = certFingerprint }
        if let harnessID { backends[idx].harnessID = harnessID }
        persist()
    }

    // MARK: - Harness controls

    /// Read a harness-specific control value (native scope, auto-approve, …).
    public func harnessControl(harnessID: String, key: String) -> HarnessSettingValue? {
        backendHarnessControls[harnessID]?[key]
    }

    /// Write a harness-specific control value. `nil` clears it (falls back to
    /// the control's default from the discovery schema).
    public func setHarnessControl(harnessID: String, key: String, value: HarnessSettingValue?) {
        var forHarness = backendHarnessControls[harnessID] ?? [:]
        if let value {
            guard forHarness[key] != value else { return }
            forHarness[key] = value
        } else {
            guard forHarness[key] != nil else { return }
            forHarness.removeValue(forKey: key)
        }
        backendHarnessControls[harnessID] = forHarness.isEmpty ? nil : forHarness
        persist()
    }

    /// All stored control values for a harness — merged into `RunAgentInput.state`.
    public func harnessControls(harnessID: String) -> [String: HarnessSettingValue] {
        backendHarnessControls[harnessID] ?? [:]
    }

    /// Remove a backend. Refuses to remove the last remaining backend (the
    /// app needs at least one — otherwise there's no URL for clients to read);
    /// auto-promotes the next available entry when the active one is removed.
    public func removeBackend(_ id: UUID) {
        guard backends.count > 1 else { return }
        guard let idx = backends.firstIndex(where: { $0.id == id }) else { return }
        backends.remove(at: idx)
        if activeBackendID == id {
            activeBackendID = backends[0].id
        }
        persist()
    }

    /// Flip which backend drives `backendURL` / `apiKey` / `authHeaders`.
    /// No-op for unknown id.
    public func setActiveBackend(_ id: UUID) {
        guard backends.contains(where: { $0.id == id }) else { return }
        guard id != activeBackendID else { return }
        activeBackendID = id
        persist()
    }

    // MARK: - Security

    public func setShellApprovalDisabled(_ disabled: Bool) {
        guard disabled != shellApprovalDisabled else { return }
        shellApprovalDisabled = disabled
        persist()
    }

    // MARK: - A2A guardrails

    /// Clamp to the supported range so a bad write (or migrated value) can't
    /// disable the gate or push it absurdly high.
    public func setA2AMaxChainDepth(_ value: Int) {
        let clamped = min(max(value, Self.a2aMaxChainDepthRange.lowerBound), Self.a2aMaxChainDepthRange.upperBound)
        guard clamped != a2aMaxChainDepth else { return }
        a2aMaxChainDepth = clamped
        persist()
    }

    public func setA2AMaxTurnsPerPair(_ value: Int) {
        let clamped = min(max(value, Self.a2aMaxTurnsPerPairRange.lowerBound), Self.a2aMaxTurnsPerPairRange.upperBound)
        guard clamped != a2aMaxTurnsPerPair else { return }
        a2aMaxTurnsPerPair = clamped
        persist()
    }

    /// Clamp to the supported range so a bad write can't strand turns (too
    /// low) or invite runaway loops (too high).
    public func setMaxToolRounds(_ value: Int) {
        let clamped = min(max(value, Self.maxToolRoundsRange.lowerBound), Self.maxToolRoundsRange.upperBound)
        guard clamped != maxToolRounds else { return }
        maxToolRounds = clamped
        persist()
    }

    public func setToolRoundsUnlimited(_ value: Bool) {
        guard value != toolRoundsUnlimited else { return }
        toolRoundsUnlimited = value
        persist()
    }

    // MARK: - Thread storage cap

    public func setThreadCapEnabled(_ value: Bool) {
        guard value != threadCapEnabled else { return }
        threadCapEnabled = value
        persist()
    }

    /// Clamp to `threadCapMBRange` and round to one decimal so the `Stepper`'s
    /// 0.1 accumulation can't drift (…4.9999999) or escape the bounds.
    public func setThreadCapMB(_ value: Double) {
        let clamped = min(max(value, Self.threadCapMBRange.lowerBound), Self.threadCapMBRange.upperBound)
        let rounded = (clamped * 10).rounded() / 10
        guard rounded != threadCapMB else { return }
        threadCapMB = rounded
        persist()
    }

    // MARK: - Orchestrator LLM

    /// Write (or clear) the orchestrator's LLM selection. Pass `nil` for
    /// either field to clear both — provider + model only apply together.
    public func setOrchestratorLLM(provider: String?, model: String?) {
        if let provider, let model, !provider.isEmpty, !model.isEmpty {
            orchestratorLLMProvider = provider
            orchestratorLLMModel = model
        } else {
            orchestratorLLMProvider = nil
            orchestratorLLMModel = nil
        }
        persist()
    }

    /// Read the orchestrator's LLM selection. Returns `nil` when either
    /// field is missing — callers fall back to the backend env default.
    public func orchestratorLLM() -> (provider: String, model: String)? {
        guard let provider = orchestratorLLMProvider,
              let model = orchestratorLLMModel else { return nil }
        return (provider, model)
    }

    /// Write (or clear) the orchestrator's disabled tool set. Empty clears it.
    public func setOrchestratorDisabledTools(_ names: Set<String>) {
        guard orchestratorDisabledTools != names else { return }
        orchestratorDisabledTools = names
        persist()
    }

    // MARK: - Auth headers

    /// Headers to add to every backend request — empty when the active
    /// backend hasn't been paired yet. The only client-side credential is the
    /// paired-device token in the Keychain (per [#163](https://github.com/*/issues/163)
    /// Phase 3b). The server-side `PUPA_API_KEY` still works as a
    /// bootstrap credential for `make pair`, but it's never given to clients.
    public var authHeaders: [String: String] {
        let active = activeBackend
        guard let deviceToken = credentials.token(for: active.id), !deviceToken.isEmpty else {
            return [:]
        }
        return ["Authorization": "Bearer \(deviceToken)"]
    }

    /// True when the active backend has a paired-device token in the
    /// credential store. Drives the 🔗 paired badge on the Settings row.
    public func isPaired(_ backendID: UUID) -> Bool {
        credentials.token(for: backendID) != nil
    }

    // MARK: - Pairing

    /// Record a successful pair: save the device token to the credential
    /// store, persist the server-side `deviceID` on the entry so we can
    /// revoke later. Throws if the credential store fails (Keychain
    /// permission error etc.) — leaves no half-paired state behind.
    public func markPaired(backendID: UUID, deviceID: UUID, token: String) throws {
        try credentials.setToken(token, for: backendID)
        updateBackend(backendID, deviceID: .some(deviceID))
    }

    /// Locally clear the pairing — removes the token from the credential
    /// store and the deviceID from the entry. The server still has the
    /// device; call `BackendDevicesClient.revoke(deviceID:)` (Phase 5) to
    /// also tell the backend.
    public func clearPairing(backendID: UUID) throws {
        try credentials.removeToken(for: backendID)
        updateBackend(backendID, deviceID: .some(nil))
    }

    // MARK: - Internals

    private func mutateActive(_ edit: (inout BackendEntry) -> Void) {
        guard let idx = backends.firstIndex(where: { $0.id == activeBackendID }) else { return }
        edit(&backends[idx])
    }

    // MARK: - Persistence

    private func persist() {
        let snap = Snapshot(
            disabledBackendTools: Array(disabledBackendTools).sorted(),
            backendHarnessControls: backendHarnessControls,
            backends: backends,
            activeBackendID: activeBackendID,
            shellApprovalDisabled: shellApprovalDisabled,
            orchestratorLLMProvider: orchestratorLLMProvider,
            orchestratorLLMModel: orchestratorLLMModel,
            orchestratorDisabledTools: Array(orchestratorDisabledTools).sorted(),
            a2aMaxChainDepth: a2aMaxChainDepth,
            a2aMaxTurnsPerPair: a2aMaxTurnsPerPair,
            maxToolRounds: maxToolRounds,
            toolRoundsUnlimited: toolRoundsUnlimited,
            threadCapEnabled: threadCapEnabled,
            threadCapMB: threadCapMB
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? CloudDocument.write(data, to: Self.settingsURL)
    }

    /// `state/settings.json` under the active storage root. Device tokens are
    /// **not** here — they stay in the Keychain, unsynced (see `credentials`).
    nonisolated static var settingsURL: URL {
        PupaStorage.stateRoot.appendingPathComponent("settings.json")
    }

    /// On-disk shape. Backwards-compatible for two old shapes:
    ///   1. Pre-#72: top-level `backendURL` (single backend, no list).
    ///   2. Pre-#163 Phase 3b: `BackendEntry.apiKey` per entry.
    /// The pre-#72 field is decoded for migration; never re-encoded. The
    /// per-entry `apiKey` is silently dropped on decode — Swift's default
    /// Codable ignores unknown JSON keys, and we don't migrate stale keys
    /// into the Keychain because we can't know whether they're still valid
    /// against the backend. Operators with paired devices already have
    /// Keychain tokens; those without need to re-pair to chat.
    private struct Snapshot: Codable {
        var disabledBackendTools: [String] = []
        // Optional so pre-existing blobs decode; `load()` substitutes [:].
        var backendHarnessControls: [String: [String: HarnessSettingValue]]?
        var backends: [BackendEntry]?
        var activeBackendID: UUID?
        var shellApprovalDisabled: Bool?
        var orchestratorLLMProvider: String?
        var orchestratorLLMModel: String?
        // Optional so pre-existing blobs decode; `load()` substitutes [].
        var orchestratorDisabledTools: [String]?
        // Optional so pre-A2A blobs decode; `load()` substitutes the defaults.
        var a2aMaxChainDepth: Int?
        var a2aMaxTurnsPerPair: Int?
        // Optional so pre-existing blobs decode; `load()` substitutes the default.
        var maxToolRounds: Int?
        var toolRoundsUnlimited: Bool?
        // Optional so pre-thread-cap blobs decode; `load()` substitutes defaults.
        var threadCapEnabled: Bool?
        var threadCapMB: Double?
        // Legacy single-backend field. Decoded for migration; never re-encoded.
        var backendURL: String?
    }

    private struct Loaded {
        let disabledTools: Set<String>
        let backendHarnessControls: [String: [String: HarnessSettingValue]]
        let backends: [BackendEntry]
        let activeBackendID: UUID
        let shellApprovalDisabled: Bool
        let orchestratorLLMProvider: String?
        let orchestratorLLMModel: String?
        let orchestratorDisabledTools: Set<String>
        let a2aMaxChainDepth: Int
        let a2aMaxTurnsPerPair: Int
        let maxToolRounds: Int
        let toolRoundsUnlimited: Bool
        let threadCapEnabled: Bool
        let threadCapMB: Double
    }

    private nonisolated static func load() -> Loaded {
        guard let data = CloudDocument.read(settingsURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            let entry = BackendEntry(label: defaultBackendLabel, url: defaultBackendURL)
            return Loaded(
                disabledTools: [],
                backendHarnessControls: [:],
                backends: [entry],
                activeBackendID: entry.id,
                shellApprovalDisabled: false,
                orchestratorLLMProvider: nil,
                orchestratorLLMModel: nil,
                orchestratorDisabledTools: [],
                a2aMaxChainDepth: defaultA2AMaxChainDepth,
                a2aMaxTurnsPerPair: defaultA2AMaxTurnsPerPair,
                maxToolRounds: defaultMaxToolRounds,
                toolRoundsUnlimited: defaultToolRoundsUnlimited,
                threadCapEnabled: false,
                threadCapMB: defaultThreadCapMB
            )
        }
        let (backends, activeID) = resolveBackends(snap)
        return Loaded(
            disabledTools: Set(snap.disabledBackendTools),
            backendHarnessControls: snap.backendHarnessControls ?? [:],
            backends: backends,
            activeBackendID: activeID,
            shellApprovalDisabled: snap.shellApprovalDisabled ?? false,
            orchestratorLLMProvider: snap.orchestratorLLMProvider,
            orchestratorLLMModel: snap.orchestratorLLMModel,
            orchestratorDisabledTools: Set(snap.orchestratorDisabledTools ?? []),
            a2aMaxChainDepth: snap.a2aMaxChainDepth ?? defaultA2AMaxChainDepth,
            a2aMaxTurnsPerPair: snap.a2aMaxTurnsPerPair ?? defaultA2AMaxTurnsPerPair,
            maxToolRounds: snap.maxToolRounds ?? defaultMaxToolRounds,
            toolRoundsUnlimited: snap.toolRoundsUnlimited ?? defaultToolRoundsUnlimited,
            threadCapEnabled: snap.threadCapEnabled ?? false,
            threadCapMB: snap.threadCapMB ?? defaultThreadCapMB
        )
    }

    private nonisolated static func resolveBackends(_ snap: Snapshot) -> ([BackendEntry], UUID) {
        // Prefer the new multi-backend shape if present and non-empty.
        if let stored = snap.backends, !stored.isEmpty {
            let active = snap.activeBackendID.flatMap { id in
                stored.first(where: { $0.id == id })?.id
            } ?? stored[0].id
            return (stored, active)
        }
        // Pre-#72 migration: build a single entry from the legacy URL field.
        let url = snap.backendURL.flatMap(URL.init(string:)) ?? defaultBackendURL
        let entry = BackendEntry(label: defaultBackendLabel, url: url)
        return ([entry], entry.id)
    }

    public static func clearStorage() {
        CloudDocument.delete(settingsURL)
    }

    /// Reload settings from disk and republish. Called by the iCloud watcher
    /// when a remote edit lands. Keychain-held tokens are untouched. The disk
    /// read runs off the main actor (pupa#110); only the republish is on main.
    public func reloadFromDisk() async {
        let loaded = await Task.detached(priority: .utility) { Self.load() }.value
        disabledBackendTools = loaded.disabledTools
        backendHarnessControls = loaded.backendHarnessControls
        backends = loaded.backends
        activeBackendID = loaded.activeBackendID
        shellApprovalDisabled = loaded.shellApprovalDisabled
        orchestratorLLMProvider = loaded.orchestratorLLMProvider
        orchestratorLLMModel = loaded.orchestratorLLMModel
        orchestratorDisabledTools = loaded.orchestratorDisabledTools
        a2aMaxChainDepth = loaded.a2aMaxChainDepth
        a2aMaxTurnsPerPair = loaded.a2aMaxTurnsPerPair
        maxToolRounds = loaded.maxToolRounds
        toolRoundsUnlimited = loaded.toolRoundsUnlimited
        threadCapEnabled = loaded.threadCapEnabled
        threadCapMB = loaded.threadCapMB
    }
}

