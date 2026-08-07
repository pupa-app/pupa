import Foundation
import Testing
@testable import PupaApp

/// Round-trip tests for `SettingsStore`'s backend list, active selection,
/// and tool-toggle persistence. Pre-Phase-3b api-key tests have been
/// removed alongside the field itself — paired-device tokens are the only
/// client-side credential now (see [`BackendPairingTests`](BackendPairingTests.swift)).
/// Persistence is the `state/settings.json` file (redirected to a temp dir by
/// `TestStorage`); `disabledBackendTools` and the backend list share it, so we
/// pin that the two concerns coexist after a save/load cycle.
@MainActor
@Suite("SettingsStore persistence", .serialized)
struct SettingsStorePersistenceTests {

    init() { TestStorage.activate() }

    private func freshStore() -> SettingsStore {
        SettingsStore.clearStorage()
        return SettingsStore(credentials: InMemoryCredentialStore())
    }

    @Test("Defaults: localhost backendURL, no disabled tools, no auth headers")
    func defaultsWhenNothingPersisted() {
        let store = freshStore()
        #expect(store.backendURL == SettingsStore.defaultBackendURL)
        #expect(store.disabledBackendTools.isEmpty)
        #expect(store.authHeaders.isEmpty)
    }

    @Test("setBackendURL persists across SettingsStore instances")
    func backendURL_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        let url = URL(string: "https://tunnel.example.com/")!
        writer.setBackendURL(url)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.backendURL == url)
    }

    @Test("Backend + tool toggles coexist in the same snapshot")
    func backendAndToolToggles_coexist() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        writer.setBackendURL(URL(string: "https://my-tunnel.example.com/")!)
        writer.setEnabled("tavily_search", to: false)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.backendURL.absoluteString == "https://my-tunnel.example.com/")
        #expect(reader.isEnabled("tavily_search") == false)
    }

    @Test("init() backendURL override takes precedence over persisted state")
    func initOverridesPersisted() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        writer.setBackendURL(URL(string: "https://persisted.example.com/")!)

        let override = SettingsStore(
            backendURL: URL(string: "https://override.example.com/")!,
            credentials: InMemoryCredentialStore()
        )
        #expect(override.backendURL.absoluteString == "https://override.example.com/")
    }

    // MARK: - Multi-backend list (#72)

    @Test("addBackend appends a new entry without changing the active selection")
    func addBackend_appendsAndKeepsActive() {
        let store = freshStore()
        let originalActive = store.activeBackendID
        let newID = store.addBackend(label: "Tunnel", url: URL(string: "https://t.example.com/")!)
        #expect(store.backends.count == 2)
        #expect(store.activeBackendID == originalActive)
        #expect(store.backends.contains { $0.id == newID })
    }

    @Test("setActiveBackend flips backendURL to the new selection")
    func setActiveBackend_flipsAccessors() {
        let store = freshStore()
        let tunnelID = store.addBackend(label: "Tunnel", url: URL(string: "https://t.example.com/")!)
        store.setActiveBackend(tunnelID)
        #expect(store.backendURL.absoluteString == "https://t.example.com/")
        // authHeaders stays empty — no device token paired yet.
        #expect(store.authHeaders.isEmpty)
    }

    @Test("Active selection + list persists across SettingsStore instances")
    func multiBackend_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        let tunnelID = writer.addBackend(label: "Tunnel", url: URL(string: "https://t.example.com/")!)
        writer.setActiveBackend(tunnelID)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.backends.count == 2)
        #expect(reader.activeBackendID == tunnelID)
        #expect(reader.backendURL.absoluteString == "https://t.example.com/")
    }

    @Test("removeBackend refuses to delete the only entry")
    func removeBackend_refusesLast() {
        let store = freshStore()
        let only = store.activeBackendID
        store.removeBackend(only)
        #expect(store.backends.count == 1)
        #expect(store.backends[0].id == only)
    }

    @Test("removeBackend on the active entry promotes another to active")
    func removeBackend_promotesNextOnActiveDeletion() {
        let store = freshStore()
        let localID = store.activeBackendID
        let tunnelID = store.addBackend(label: "Tunnel", url: URL(string: "https://t.example.com/")!)
        store.setActiveBackend(tunnelID)
        store.removeBackend(tunnelID)
        #expect(store.backends.count == 1)
        #expect(store.activeBackendID == localID)
    }

    @Test("updateBackend edits label / url for a known id")
    func updateBackend_editsFields() {
        let store = freshStore()
        let id = store.addBackend(label: "Old", url: URL(string: "https://old.example.com/")!)
        store.updateBackend(
            id,
            label: "New",
            url: URL(string: "https://new.example.com/")!
        )
        let edited = store.backends.first { $0.id == id }!
        #expect(edited.label == "New")
        #expect(edited.url.absoluteString == "https://new.example.com/")
    }

    // MARK: - Max tool rounds (per-turn cap)

    @Test("maxToolRounds defaults to the documented value")
    func maxToolRounds_default() {
        let store = freshStore()
        #expect(store.maxToolRounds == SettingsStore.defaultMaxToolRounds)
    }

    @Test("setMaxToolRounds persists across SettingsStore instances")
    func maxToolRounds_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        writer.setMaxToolRounds(40)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.maxToolRounds == 40)
    }

    @Test("setMaxToolRounds clamps to the supported range")
    func maxToolRounds_clamps() {
        let store = freshStore()
        store.setMaxToolRounds(9999)
        #expect(store.maxToolRounds == SettingsStore.maxToolRoundsRange.upperBound)
        store.setMaxToolRounds(0)
        #expect(store.maxToolRounds == SettingsStore.maxToolRoundsRange.lowerBound)
    }

    @Test("toolRoundsUnlimited round-trips and drives effectiveMaxToolRounds")
    func toolRoundsUnlimited_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        // On by default → no client-side breaker.
        #expect(writer.toolRoundsUnlimited == true)
        #expect(writer.effectiveMaxToolRounds == nil)

        // Switching the breaker on hands the session the numeric value.
        writer.setToolRoundsUnlimited(false)
        #expect(writer.effectiveMaxToolRounds == writer.maxToolRounds)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.toolRoundsUnlimited == false)
        #expect(reader.effectiveMaxToolRounds == reader.maxToolRounds)
    }

    /// The cap defaults off: a finite default cut long agentic turns short, and
    /// the turn reported clean, so the stop was invisible. Existing installs
    /// have no `toolRoundsUnlimited` key and must migrate to unlimited too.
    @Test("Tool rounds are uncapped by default, including for a pre-existing settings blob")
    func toolRounds_defaultUnlimited() throws {
        let fresh = freshStore()
        #expect(fresh.toolRoundsUnlimited == SettingsStore.defaultToolRoundsUnlimited)
        #expect(fresh.effectiveMaxToolRounds == nil)

        SettingsStore.clearStorage()
        let id = UUID()
        let legacy: [String: Any] = [
            "disabledBackendTools": [],
            "backends": [["id": id.uuidString, "label": "L", "url": "https://x.example.com/"]],
            "activeBackendID": id.uuidString,
        ]
        try CloudDocument.write(
            try JSONSerialization.data(withJSONObject: legacy), to: SettingsStore.settingsURL)

        let migrated = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(migrated.toolRoundsUnlimited == true)
        #expect(migrated.effectiveMaxToolRounds == nil)
    }

    @Test("Pre-existing settings blob without maxToolRounds decodes to the default")
    func maxToolRounds_absentDecodesToDefault() throws {
        SettingsStore.clearStorage()
        let id = UUID()
        let legacy: [String: Any] = [
            "disabledBackendTools": [],
            "backends": [["id": id.uuidString, "label": "L", "url": "https://x.example.com/"]],
            "activeBackendID": id.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try CloudDocument.write(data, to: SettingsStore.settingsURL)

        let store = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(store.maxToolRounds == SettingsStore.defaultMaxToolRounds)
    }

    // MARK: - Agent harness (per-connection selection)

    @Test("harnessID persists and drives agentRunURL")
    func harnessID_roundtripAndRunURL() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        let id = writer.addBackend(label: "Multi", url: URL(string: "https://m.example.com/")!)
        writer.setActiveBackend(id)
        // No harness selected → run endpoint is the bare URL (backend default).
        #expect(writer.agentRunURL.absoluteString == "https://m.example.com/")

        writer.updateBackend(id, harnessID: .some("claude_code"))
        #expect(writer.agentRunURL.absoluteString == "https://m.example.com/harnesses/claude_code")

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.activeBackend.harnessID == "claude_code")
        #expect(reader.agentRunURL.absoluteString == "https://m.example.com/harnesses/claude_code")
    }

    @Test("addBackend(entry) preserves id + harnessID and persists")
    func addBackendEntry_preservesIdentity() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        let entry = BackendEntry(label: "", url: URL(string: "https://e.example.com/")!, harnessID: "claude_code")
        writer.addBackend(entry)
        writer.setActiveBackend(entry.id)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        let stored = reader.backends.first { $0.id == entry.id }
        #expect(stored != nil)
        #expect(stored?.harnessID == "claude_code")
        // Re-adding the same id is a no-op (no duplicate row).
        reader.addBackend(entry)
        #expect(reader.backends.filter { $0.id == entry.id }.count == 1)
    }

    @Test("randomBackendLabel is non-empty and varies")
    func randomBackendLabel_nonEmpty() {
        let a = SettingsStore.randomBackendLabel()
        let b = SettingsStore.randomBackendLabel()
        #expect(!a.isEmpty)
        #expect(a != b)
    }

    @Test("harness controls round-trip per harness id")
    func harnessControls_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        writer.setHarnessControl(harnessID: "claude_code", key: "claude_loop_native", value: .string("read"))
        writer.setHarnessControl(harnessID: "claude_code", key: "claude_loop_auto_approve", value: .bool(true))

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.harnessControl(harnessID: "claude_code", key: "claude_loop_native") == .string("read"))
        #expect(reader.harnessControl(harnessID: "claude_code", key: "claude_loop_auto_approve") == .bool(true))
        // A different harness has no controls stored.
        #expect(reader.harnessControls(harnessID: "deepagents").isEmpty)
    }

    @Test("clearing a harness control removes it (falls back to default)")
    func harnessControls_clear() {
        let store = freshStore()
        store.setHarnessControl(harnessID: "claude_code", key: "claude_loop_native", value: .string("off"))
        store.setHarnessControl(harnessID: "claude_code", key: "claude_loop_native", value: nil)
        #expect(store.harnessControl(harnessID: "claude_code", key: "claude_loop_native") == nil)
    }

    @Test("Pre-harness settings blob decodes: no harnessID, empty controls")
    func preHarness_blobDecodes() throws {
        SettingsStore.clearStorage()
        let id = UUID()
        let legacy: [String: Any] = [
            "disabledBackendTools": ["tavily_search"],
            "backends": [["id": id.uuidString, "label": "L", "url": "https://x.example.com/"]],
            "activeBackendID": id.uuidString,
            "shellApprovalDisabled": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try CloudDocument.write(data, to: SettingsStore.settingsURL)

        let store = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(store.activeBackend.harnessID == nil)
        #expect(store.agentRunURL.absoluteString == "https://x.example.com/")
        #expect(store.backendHarnessControls.isEmpty)
        // Existing fields still migrate as before.
        #expect(store.isEnabled("tavily_search") == false)
        #expect(store.shellApprovalDisabled == true)
    }

    @Test("settings.json with a per-entry apiKey decodes cleanly (unknown key dropped)")
    func preParingApiKey_silentlyDropped() throws {
        SettingsStore.clearStorage()
        // Hand-write a settings file carrying a stale per-entry apiKey field.
        let id = UUID()
        let legacy: [String: Any] = [
            "disabledBackendTools": [],
            "backends": [
                [
                    "id": id.uuidString,
                    "label": "Tunnel",
                    "url": "https://tunnel.example.com/",
                    "apiKey": "stale-key-shouldnt-be-resurrected",
                ]
            ],
            "activeBackendID": id.uuidString,
            "shellApprovalDisabled": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try CloudDocument.write(data, to: SettingsStore.settingsURL)

        let store = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(store.backends.count == 1)
        #expect(store.backendURL.absoluteString == "https://tunnel.example.com/")
        // No Keychain token paired yet → empty auth headers; the stale apiKey
        // is *not* automatically migrated.
        #expect(store.authHeaders.isEmpty)
    }

    // MARK: - Thread storage cap (auto-delete old chats)

    @Test("threadCap defaults: disabled, default MB, no effective cap")
    func threadCap_defaults() {
        let store = freshStore()
        #expect(store.threadCapEnabled == false)
        #expect(abs(store.threadCapMB - SettingsStore.defaultThreadCapMB) < 1e-9)
        // Disabled → no cap applied regardless of the stored MB value.
        #expect(store.effectiveThreadCapBytes == nil)
    }

    @Test("threadCap enabled + MB round-trip across instances; drives effective bytes")
    func threadCap_roundtrip() {
        SettingsStore.clearStorage()
        let writer = SettingsStore(credentials: InMemoryCredentialStore())
        writer.setThreadCapEnabled(true)
        writer.setThreadCapMB(2.5)
        #expect(writer.effectiveThreadCapBytes == 2_500_000)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.threadCapEnabled == true)
        #expect(abs(reader.threadCapMB - 2.5) < 1e-9)
        #expect(reader.effectiveThreadCapBytes == 2_500_000)
    }

    @Test("effectiveThreadCapBytes is nil while disabled even with an MB set")
    func threadCap_disabledYieldsNilBytes() {
        let store = freshStore()
        store.setThreadCapMB(1.0)
        #expect(store.effectiveThreadCapBytes == nil)
        store.setThreadCapEnabled(true)
        #expect(store.effectiveThreadCapBytes == 1_000_000)
    }

    @Test("setThreadCapMB clamps to the supported range")
    func threadCap_clamps() {
        let store = freshStore()
        store.setThreadCapMB(9_999)
        #expect(abs(store.threadCapMB - SettingsStore.threadCapMBRange.upperBound) < 1e-9)
        store.setThreadCapMB(-5)
        #expect(abs(store.threadCapMB - SettingsStore.threadCapMBRange.lowerBound) < 1e-9)
    }

    @Test("setThreadCapMB rounds to one decimal to avoid float-step drift")
    func threadCap_roundsToOneDecimal() {
        let store = freshStore()
        store.setThreadCapEnabled(true)
        store.setThreadCapMB(0.44)   // → 0.4
        #expect(store.effectiveThreadCapBytes == 400_000)
        store.setThreadCapMB(0.47)   // → 0.5
        #expect(store.effectiveThreadCapBytes == 500_000)
    }

    @Test("Pre-existing settings blob without threadCap fields decodes to defaults")
    func threadCap_absentDecodesToDefault() throws {
        SettingsStore.clearStorage()
        let id = UUID()
        let legacy: [String: Any] = [
            "disabledBackendTools": [],
            "backends": [["id": id.uuidString, "label": "L", "url": "https://x.example.com/"]],
            "activeBackendID": id.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try CloudDocument.write(data, to: SettingsStore.settingsURL)

        let store = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(store.threadCapEnabled == false)
        #expect(abs(store.threadCapMB - SettingsStore.defaultThreadCapMB) < 1e-9)
        #expect(store.effectiveThreadCapBytes == nil)
    }
}
