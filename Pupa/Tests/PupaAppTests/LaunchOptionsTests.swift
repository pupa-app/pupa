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

    /// The safety property: no storage root, no scripted backend — even when a
    /// script was named. Otherwise a stray argument would silently cut a real
    /// user's app off from its backend.
    @Test("a script without a storage root is ignored")
    func scriptWithoutRoot_isIgnored() {
        let values = LaunchOptions.parse(["Pupa", "-PupaScript", "/tmp/script.jsonl"])
        #expect(values.scriptPath == "/tmp/script.jsonl")
        #expect(values.isDriven == false, "no root means nothing is applied")
    }
}
