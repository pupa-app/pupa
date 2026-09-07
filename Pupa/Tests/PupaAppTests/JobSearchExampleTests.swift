import CryptoKit
import Foundation
import Testing
@testable import PupaApp

/// Pins the seeded "Job Search & Apply" workspace: that the embedded
/// marketplace bundle is the published one, that it decodes into the four
/// components the agent addresses by id, and that its memory layer (agents,
/// skills, automation) lands without clobbering user edits.
@MainActor
@Suite("JobSearchExample seed")
struct JobSearchExampleTests {

    /// `sha256` of `apps/job-search-apply/app.pupa` as published in the
    /// marketplace `index.json`. Update both together — an unexplained
    /// mismatch means the embedded copy was hand-edited.
    static let publishedSHA256 =
        "a9bdd1521c67c003ad00a8bf8ab3bfaef5884aba40727d8366b485243510f7a5"

    @Test("Embedded resource is the published marketplace bundle, byte for byte")
    func embeddedResourceMatchesMarketplace() throws {
        let url = try #require(JobSearchExample.resourceURL)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.publishedSHA256)

        let bundle = JobSearchExample.bundle
        #expect(bundle.header.format == MyAppBundle.formatMagic)
        #expect(bundle.header.formatVersion <= MyAppBundle.currentFormatVersion)
        #expect(bundle.app.name == JobSearchExample.name)
    }

    @Test("make() returns the bundle's four components with stable ids")
    func makeSeedHasBundleComponents() {
        let myApp = JobSearchExample.make()
        #expect(myApp.name == JobSearchExample.name)
        #expect(myApp.typeId == "tracker")
        #expect(myApp.iconSystemName == "briefcase")
        #expect(myApp.activeComponentId == "tracker-3")

        let ids = Set(myApp.components.map(\.id))
        #expect(ids == ["tracker-3", "tracker-1", "calendar-1", "checklist-1"])
        #expect(myApp.components.allSatisfy { !$0.isLocked })
    }

    @Test("Each call allocates a fresh app id and thread")
    func makeIsFreshEachCall() {
        let first = JobSearchExample.make()
        let second = JobSearchExample.make()
        #expect(first.id != second.id)
        #expect(first.currentThreadId != second.currentThreadId)
        #expect(first.threads.count == 1)
        #expect(first.threads[0].id == first.currentThreadId)
    }

    @Test("Job Search tracker carries the scoring pipeline fields, no seed rows")
    func jobTrackerIsTheScoringPipeline() {
        let myApp = JobSearchExample.make()
        guard case .tracker(let data) = body(myApp, id: "tracker-3") else {
            Issue.record("tracker-3 missing or wrong kind"); return
        }
        let fieldNames = Set(data.fields.map(\.name))
        #expect(fieldNames.isSuperset(of: [
            "company", "role", "status", "score", "tier", "url",
            "skillsScore", "expScore", "cultureScore",
        ]))
        #expect(data.columnField == "status")
        let status = data.fields.first(where: { $0.name == "status" })
        #expect(status?.options?.contains("To Apply") == true)
        // Ships empty — `/setup` then `/job-search` fill it.
        #expect(data.items.isEmpty)
    }

    @Test("Relevant Events tracker ships the ranking fields, no seed rows")
    func eventsTrackerIsTheRankingBoard() {
        let myApp = JobSearchExample.make()
        guard case .tracker(let data) = body(myApp, id: "tracker-1") else {
            Issue.record("tracker-1 missing or wrong kind"); return
        }
        let fieldNames = Set(data.fields.map(\.name))
        #expect(fieldNames.isSuperset(of: ["name", "type", "relevance", "tier", "status"]))
        #expect(data.items.isEmpty)
    }

    @Test("Deadlines calendar and Application Steps checklist ship empty")
    func calendarAndChecklistShipEmpty() {
        let myApp = JobSearchExample.make()
        guard case .calendar(let cal) = body(myApp, id: "calendar-1") else {
            Issue.record("calendar-1 missing or wrong kind"); return
        }
        guard case .checklist(let list) = body(myApp, id: "checklist-1") else {
            Issue.record("checklist-1 missing or wrong kind"); return
        }
        #expect(cal.events.isEmpty)
        #expect(list.items.isEmpty)
    }

    @Test("seedAgentsMd writes the bundle's agents, skills and automations, minus the guide plugin")
    func seedWritesMemoryLayer() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-job-search-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        let global = MemoryStore(rootOverride: tmpBase)
        let appRoot = tmpBase.appendingPathComponent("example-job-search", isDirectory: true)
        JobSearchExample.seedAgentsMd(globalMemory: global, appRoot: appRoot)
        let appMemory = MemoryStore(rootOverride: appRoot)

        var expected = ["pupa/AGENTS.md", MemoryStore.pupaAutomationsPath]
        expected += ["job-scout", "doc-writer", "contact-scout", "event-scout"]
            .map { "pupa/agents/\($0)/AGENTS.md" }
        expected += ["setup", "job-search", "apply-job", "find-contacts", "find-events"]
            .map { "\(MemoryStore.pupaSkillsDir)/\($0)/SKILL.md" }
        for path in expected {
            #expect(appMemory.fileExists(at: path), "\(path) missing after seed")
        }

        // The guide plugin is managed by `GuideSkills`, not shipped by the seed.
        #expect(JobSearchExample.seededMemories.allSatisfy {
            !$0.path.hasPrefix("\(MemoryStore.pupaPluginsDir)/")
        })
        #expect(appMemory.fileExists(at: "\(GuideSkills.pluginDir)/skills/pupa/SKILL.md") == false)

        // Content survives the round trip intact — guards silent truncation.
        let appMd = try String(contentsOf: appRoot.appendingPathComponent("pupa/AGENTS.md"), encoding: .utf8)
        #expect(appMd.contains("Components"))
        #expect(appMd.contains("/apply-job"))
        let rules = try String(
            contentsOf: appRoot.appendingPathComponent(MemoryStore.pupaAutomationsPath), encoding: .utf8)
        #expect(rules.contains("item.moved"))
    }

    @Test("seedAgentsMd is idempotent and never clobbers a user edit")
    func seedIsIdempotent() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-job-search-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        let global = MemoryStore(rootOverride: tmpBase)
        let appRoot = tmpBase.appendingPathComponent("example-job-search", isDirectory: true)
        JobSearchExample.seedAgentsMd(globalMemory: global, appRoot: appRoot)

        let scoutUrl = appRoot.appendingPathComponent("pupa/agents/job-scout/AGENTS.md")
        try "# User-edited\n".write(to: scoutUrl, atomically: true, encoding: .utf8)
        JobSearchExample.seedAgentsMd(globalMemory: global, appRoot: appRoot)
        let after = try String(contentsOf: scoutUrl, encoding: .utf8)
        #expect(after == "# User-edited\n", "Second seed clobbered the user edit")
    }

    @Test("restoreExampleMyApp inserts the example then is a no-op when called again")
    func restoreIsIdempotent() {
        let placeholder = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: "tracker"
        )
        let store = MyAppStore(initial: ([placeholder], placeholder.id))
        #expect(store.myApps.contains(where: { $0.name == JobSearchExample.name }) == false)

        let firstId = store.restoreExampleMyApp()
        #expect(store.myApps.count == 2)
        #expect(store.activeMyAppId == firstId)

        store.setActive(placeholder.id)
        let secondId = store.restoreExampleMyApp()
        #expect(secondId == firstId)
        #expect(store.myApps.count == 2)
        #expect(store.activeMyAppId == firstId)
    }

    // MARK: - Helpers

    private func body(_ myApp: MyApp, id: String) -> CanvasApp? {
        myApp.components.first(where: { $0.id == id })?.body
    }
}
