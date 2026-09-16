import Foundation
import Testing
@testable import PupaApp

// MARK: - Helpers

private func makeSource(shellApprovalDisabled: Bool = false) -> GlobalSettingsSource {
    GlobalSettingsSource(shellApprovalDisabled: shellApprovalDisabled)
}

private func makeSettings(
    globalShell: Bool = false,
    miniAppOverrides: [UUID: [String: SettingValue]] = [:]
) -> EffectiveSettings {
    EffectiveSettings(
        globalSource: makeSource(shellApprovalDisabled: globalShell),
        miniAppSettings: miniAppOverrides
    )
}

// MARK: - Resolution precedence

@Suite("EffectiveSettings resolution")
struct EffectiveSettingsTests {

    @Test("Global default: false when nothing set")
    func globalDefault() {
        let es = makeSettings(globalShell: false)
        let v = es.resolve(ShellApprovalDisabledKey.self, at: .global)
        #expect(v == false)
    }

    @Test("Global layer: true when globalSource says true")
    func globalTrue() {
        let es = makeSettings(globalShell: true)
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .global) == true)
    }

    @Test("MiniApp layer overrides global (true overrides false)")
    func miniAppOverridesGlobal_trueOverFalse() {
        let id = UUID()
        let es = makeSettings(
            globalShell: false,
            miniAppOverrides: [id: [ShellApprovalDisabledKey.name: .bool(true)]]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .miniApp(id)) == true)
    }

    @Test("MiniApp layer overrides global (false overrides true)")
    func miniAppOverridesGlobal_falseOverTrue() {
        let id = UUID()
        let es = makeSettings(
            globalShell: true,
            miniAppOverrides: [id: [ShellApprovalDisabledKey.name: .bool(false)]]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .miniApp(id)) == false)
    }

    @Test("MiniApp layer absent: falls back to global")
    func miniAppAbsent_fallsBackToGlobal() {
        let id = UUID()
        let otherId = UUID()
        let es = makeSettings(
            globalShell: true,
            miniAppOverrides: [otherId: [ShellApprovalDisabledKey.name: .bool(false)]]
        )
        // id has no override → picks up global true
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .miniApp(id)) == true)
    }

    @Test("Component scope falls through to miniApp then global")
    func componentFallsThrough() {
        let miniAppId = UUID()
        let es = makeSettings(
            globalShell: false,
            miniAppOverrides: [miniAppId: [ShellApprovalDisabledKey.name: .bool(true)]]
        )
        let v = es.resolve(ShellApprovalDisabledKey.self, at: .component(miniAppId: miniAppId, componentId: "tracker-1"))
        #expect(v == true)
    }

    @Test("Component scope with no miniApp override falls to global")
    func componentFallsToGlobal() {
        let miniAppId = UUID()
        let es = makeSettings(globalShell: true, miniAppOverrides: [:])
        let v = es.resolve(ShellApprovalDisabledKey.self, at: .component(miniAppId: miniAppId, componentId: "tracker-1"))
        #expect(v == true)
    }
}

// MARK: - SettingValue round-trip

@Suite("SettingValue Codable round-trip")
struct SettingValueCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("Bool round-trip")
    func boolRoundTrip() throws {
        let v = SettingValue.bool(true)
        let data = try encoder.encode(v)
        let decoded = try decoder.decode(SettingValue.self, from: data)
        #expect(decoded == .bool(true))
    }

    @Test("String round-trip")
    func stringRoundTrip() throws {
        let v = SettingValue.string("hello")
        let data = try encoder.encode(v)
        let decoded = try decoder.decode(SettingValue.self, from: data)
        #expect(decoded == .string("hello"))
    }

    @Test("Int round-trip")
    func intRoundTrip() throws {
        let v = SettingValue.int(42)
        let data = try encoder.encode(v)
        let decoded = try decoder.decode(SettingValue.self, from: data)
        #expect(decoded == .int(42))
    }
}

// MARK: - ShellApproval integration with MiniAppStore

@MainActor
@Suite("ShellApproval per-MiniApp settings via MiniAppStore")
struct ShellApprovalSettingsTests {

    @Test("setMiniAppSetting stores bool override")
    func storesBoolOverride() {
        let store = MiniAppStore(initial: nil)
        let miniAppId = store.addMiniApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMiniAppSetting(ShellApprovalDisabledKey.self, value: true, for: miniAppId)
        let miniApp = store.miniApp(withId: miniAppId)
        #expect(miniApp?.settings[ShellApprovalDisabledKey.name] == .bool(true))
    }

    @Test("setMiniAppSetting nil clears the override")
    func clearsOverride() {
        let store = MiniAppStore(initial: nil)
        let miniAppId = store.addMiniApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMiniAppSetting(ShellApprovalDisabledKey.self, value: true, for: miniAppId)
        store.setMiniAppSetting(ShellApprovalDisabledKey.self, value: nil, for: miniAppId)
        let miniApp = store.miniApp(withId: miniAppId)
        #expect(miniApp?.settings[ShellApprovalDisabledKey.name] == nil)
    }

    @Test("Per-miniApp override beats global in EffectiveSettings")
    func overrideBeatsGlobal() {
        let store = MiniAppStore(initial: nil)
        let miniAppId = store.addMiniApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMiniAppSetting(ShellApprovalDisabledKey.self, value: true, for: miniAppId)

        let miniApp = store.miniApp(withId: miniAppId)!
        let es = EffectiveSettings(
            globalSource: GlobalSettingsSource(shellApprovalDisabled: false),
            miniAppSettings: [miniAppId: miniApp.settings]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .miniApp(miniAppId)) == true)
    }

    @Test("Absence of override defers to global")
    func absenceDefersToGlobal() {
        let store = MiniAppStore(initial: nil)
        let miniAppId = store.addMiniApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        // No override set

        let miniApp = store.miniApp(withId: miniAppId)!
        let es = EffectiveSettings(
            globalSource: GlobalSettingsSource(shellApprovalDisabled: true),
            miniAppSettings: [miniAppId: miniApp.settings]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .miniApp(miniAppId)) == true)
    }
}
