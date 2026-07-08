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
        // Off by default → effective cap is the numeric value.
        #expect(writer.toolRoundsUnlimited == false)
        #expect(writer.effectiveMaxToolRounds == writer.maxToolRounds)

        writer.setToolRoundsUnlimited(true)
        #expect(writer.effectiveMaxToolRounds == nil)

        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.toolRoundsUnlimited == true)
        #expect(reader.effectiveMaxToolRounds == nil)
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
        #expect(reader.harnessControls(harnessID: "langgraph").isEmpty)
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
}
