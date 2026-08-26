import Foundation
import Testing
@testable import PupaApp

/// The launch seam a driven app comes up on. Its whole safety property is that
/// it is inert without `-PupaStorageRoot`: nothing here may point the app at a
/// script, a backend, or a seeded store while it is running on real app data.
@Suite("Launch options")
struct LaunchOptionsTests {

    @Test("a plain launch asks for nothing")
    func plainLaunch_isInert() {
        let values = LaunchOptions.parse(["Pupa"])
        #expect(values.storageRoot == nil)
        #expect(values.backendURL == nil)
        #expect(values.scriptPath == nil)
        #expect(values.skipOnboarding == false)
        #expect(values.isDriven == false)
    }

    @Test("every flag parses")
    func drivenLaunch_parsesEveryFlag() {
        let values = LaunchOptions.parse([
            "Pupa",
            "-PupaStorageRoot", "/tmp/ui",
            "-PupaBackendURL", "http://example.invalid/",
            "-PupaScript", "/tmp/script.jsonl",
            "-PupaSkipOnboarding", "1",
        ])
        #expect(values.storageRoot?.path == "/tmp/ui")
        #expect(values.backendURL?.absoluteString == "http://example.invalid/")
        #expect(values.scriptPath == "/tmp/script.jsonl")
        #expect(values.skipOnboarding)
        #expect(values.isDriven)
    }

    /// A flag whose value is missing must not swallow the next flag.
    @Test("a valueless flag doesn't eat the one after it")
    func missingValue_doesNotConsumeNextFlag() {
        let values = LaunchOptions.parse(["Pupa", "-PupaBackendURL", "-PupaStorageRoot", "/tmp/ui"])
        #expect(values.backendURL == nil)
        #expect(values.storageRoot?.path == "/tmp/ui")
    }

    /// The safety property: no storage root, nothing at all — `parse` drops
    /// every other value rather than leaving it for a caller to honour. It
    /// used to keep them, and `RootView` reads `backendURL` off this return
    /// directly, so a stray `-PupaBackendURL` cut a real user's app off from
    /// its backend.
    @Test("no storage root clears every other flag")
    func withoutRoot_everythingIsDropped() {
        let values = LaunchOptions.parse([
            "Pupa",
            "-PupaScript", "/tmp/script.jsonl",
            "-PupaBackendURL", "http://example.invalid/",
            "-PupaHarness", "claude_code",
            "-PupaSkipOnboarding", "1",
        ])
        #expect(values.isDriven == false)
        #expect(values.scriptPath == nil)
        #expect(values.backendURL == nil)
        #expect(values.harnessID == nil)
        #expect(values.skipOnboarding == false)
    }

    @Test("harness, token and clock flags parse")
    func drivenLaunch_parsesRecoveryFlags() {
        let values = LaunchOptions.parse([
            "Pupa",
            "-PupaStorageRoot", "/tmp/ui",
            "-PupaHarness", "claude_code",
            "-PupaBackendToken", "tok-123",
            "-PupaBackgroundGrace", "2",
            "-PupaReattachAttempts", "1",
            "-PupaReattachDelayMs", "50",
        ])
        #expect(values.harnessID == "claude_code")
        #expect(values.backendToken == "tok-123")
        #expect(values.backgroundGrace == 2)
        #expect(values.reattachAttempts == 1)
        #expect(values.reattachDelayNanos == 50_000_000)
    }

    /// Bare `ephemeral` is per-launch; the named form is the same dir every
    /// time, which is what lets a test kill the app and relaunch onto the
    /// state it left behind.
    @Test("a named ephemeral root is stable across launches")
    func stickyRoot_isStable() {
        func root(_ raw: String) -> String? {
            LaunchOptions.parse(["Pupa", "-PupaStorageRoot", raw]).storageRoot?.path
        }
        #expect(root("ephemeral") != root("ephemeral"))
        #expect(root("ephemeral:books") == root("ephemeral:books"))
        #expect(root("ephemeral:books") != root("ephemeral:other"))
        #expect(root("/tmp/ui") == "/tmp/ui")
        // Path separators in the name must not escape the temp dir.
        #expect(root("ephemeral:../../etc")?.contains("..") == false)
    }

    @Test("reset is opt-in, so a relaunch keeps the state it left")
    func storageReset_isOptIn() {
        #expect(LaunchOptions.parse(["Pupa", "-PupaStorageRoot", "/tmp/ui"]).resetStorage == false)
        let reset = LaunchOptions.parse([
            "Pupa", "-PupaStorageRoot", "/tmp/ui", "-PupaStorageReset", "1",
        ])
        #expect(reset.resetStorage)
    }
}
