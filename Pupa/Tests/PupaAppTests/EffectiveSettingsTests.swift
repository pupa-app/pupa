import Foundation
import Testing
@testable import PupaApp

// MARK: - Helpers

private func makeSource(shellApprovalDisabled: Bool = false) -> GlobalSettingsSource {
    GlobalSettingsSource(shellApprovalDisabled: shellApprovalDisabled)
}

private func makeSettings(
    globalShell: Bool = false,
    myAppOverrides: [UUID: [String: SettingValue]] = [:]
) -> EffectiveSettings {
    EffectiveSettings(
        globalSource: makeSource(shellApprovalDisabled: globalShell),
        myAppSettings: myAppOverrides
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

    @Test("MyApp layer overrides global (true overrides false)")
    func myAppOverridesGlobal_trueOverFalse() {
        let id = UUID()
        let es = makeSettings(
            globalShell: false,
            myAppOverrides: [id: [ShellApprovalDisabledKey.name: .bool(true)]]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .myApp(id)) == true)
    }

    @Test("MyApp layer overrides global (false overrides true)")
    func myAppOverridesGlobal_falseOverTrue() {
        let id = UUID()
        let es = makeSettings(
            globalShell: true,
            myAppOverrides: [id: [ShellApprovalDisabledKey.name: .bool(false)]]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .myApp(id)) == false)
    }

    @Test("MyApp layer absent: falls back to global")
    func myAppAbsent_fallsBackToGlobal() {
        let id = UUID()
        let otherId = UUID()
        let es = makeSettings(
            globalShell: true,
            myAppOverrides: [otherId: [ShellApprovalDisabledKey.name: .bool(false)]]
        )
        // id has no override → picks up global true
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .myApp(id)) == true)
    }

    @Test("Component scope falls through to myApp then global")
    func componentFallsThrough() {
        let myAppId = UUID()
        let es = makeSettings(
            globalShell: false,
            myAppOverrides: [myAppId: [ShellApprovalDisabledKey.name: .bool(true)]]
        )
        let v = es.resolve(ShellApprovalDisabledKey.self, at: .component(myAppId: myAppId, componentId: "tracker-1"))
        #expect(v == true)
    }

    @Test("Component scope with no myApp override falls to global")
    func componentFallsToGlobal() {
        let myAppId = UUID()
        let es = makeSettings(globalShell: true, myAppOverrides: [:])
        let v = es.resolve(ShellApprovalDisabledKey.self, at: .component(myAppId: myAppId, componentId: "tracker-1"))
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

// MARK: - ShellApproval integration with MyAppStore

@MainActor
@Suite("ShellApproval per-MyApp settings via MyAppStore")
struct ShellApprovalSettingsTests {

    @Test("setMyAppSetting stores bool override")
    func storesBoolOverride() {
        let store = MyAppStore(initial: nil)
        let myAppId = store.addMyApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMyAppSetting(ShellApprovalDisabledKey.self, value: true, for: myAppId)
        let myApp = store.myApp(withId: myAppId)
        #expect(myApp?.settings[ShellApprovalDisabledKey.name] == .bool(true))
    }

    @Test("setMyAppSetting nil clears the override")
    func clearsOverride() {
        let store = MyAppStore(initial: nil)
        let myAppId = store.addMyApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMyAppSetting(ShellApprovalDisabledKey.self, value: true, for: myAppId)
        store.setMyAppSetting(ShellApprovalDisabledKey.self, value: nil, for: myAppId)
        let myApp = store.myApp(withId: myAppId)
        #expect(myApp?.settings[ShellApprovalDisabledKey.name] == nil)
    }

    @Test("Per-myApp override beats global in EffectiveSettings")
    func overrideBeatsGlobal() {
        let store = MyAppStore(initial: nil)
        let myAppId = store.addMyApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        store.setMyAppSetting(ShellApprovalDisabledKey.self, value: true, for: myAppId)

        let myApp = store.myApp(withId: myAppId)!
        let es = EffectiveSettings(
            globalSource: GlobalSettingsSource(shellApprovalDisabled: false),
            myAppSettings: [myAppId: myApp.settings]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) == true)
    }

    @Test("Absence of override defers to global")
    func absenceDefersToGlobal() {
        let store = MyAppStore(initial: nil)
        let myAppId = store.addMyApp(typeId: "tracker", name: "My App", iconSystemName: "star")
        // No override set

        let myApp = store.myApp(withId: myAppId)!
        let es = EffectiveSettings(
            globalSource: GlobalSettingsSource(shellApprovalDisabled: true),
            myAppSettings: [myAppId: myApp.settings]
        )
        #expect(es.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) == true)
    }
}
