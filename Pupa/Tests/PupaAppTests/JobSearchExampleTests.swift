import Foundation
import Testing
@testable import PupaApp

/// Pins the shape of the seeded "Job Search" workspace so an
/// accidental edit to the factory doesn't silently strip an
/// onboarding-critical component, change a stable component id the
/// agent addresses by name, or break the cross-component link graph
/// the demo's value depends on.
@MainActor
@Suite("JobSearchExample seed")
struct JobSearchExampleTests {

    @Test("make() returns a MyApp with all seven onboarding components")
    func makeSeedHasAllComponents() {
        let myApp = JobSearchExample.make()
        #expect(myApp.name == JobSearchExample.name)
        #expect(myApp.typeId == "tracker")
        #expect(myApp.iconSystemName == "briefcase")
        #expect(myApp.activeComponentId == "tracker-1")

        let ids = myApp.components.map(\.id)
        #expect(ids == [
            "tracker-1",
            "tracker-2",
            "checklist-1",
            "checklist-2",
            "checklist-3",
            "calendar-1",
            "slack-1",
        ])
    }

    @Test("Skills tracker is populated with fields and rows")
    func skillsTrackerIsPopulated() {
        let myApp = JobSearchExample.make()
        guard case .tracker(let data) = body(myApp, id: "tracker-1") else {
            Issue.record("tracker-1 missing or wrong kind"); return
        }
        #expect(data.fields.count >= 4)
        #expect(data.fields.contains(where: { $0.name == "category" && $0.type == .select }))
        #expect(data.fields.contains(where: { $0.name == "confidence" && $0.type == .select }))
        #expect(data.items.count >= 5)
        // Every row should have a name — that's the column users read first.
        #expect(data.items.allSatisfy { ($0.values["name"] ?? "").isEmpty == false })
    }

    @Test("Experience Library has STAR-shaped stories linked back to Skills rows")
    func experienceLibraryHasStoriesLinkedToSkills() {
        let myApp = JobSearchExample.make()
        guard case .tracker(let stories) = body(myApp, id: "tracker-2") else {
            Issue.record("tracker-2 missing or wrong kind"); return
        }
        // STAR + title + category — six fields minimum.
        let fieldNames = Set(stories.fields.map(\.name))
        #expect(fieldNames.isSuperset(of: ["title", "category", "situation", "task", "action", "result"]))
        #expect(stories.items.count >= 4)

        // Every story has every STAR section non-empty — empty STAR
        // sections defeat the point of the library.
        for story in stories.items {
            for section in ["situation", "task", "action", "result"] {
                #expect((story.values[section] ?? "").isEmpty == false,
                        "Story '\(story.values["title"] ?? "?")' missing \(section)")
            }
        }

        // Every story links to at least one Skills row (the whole
        // point of the library is to wire stories to demonstrated
        // skills).
        let skillIds = skillIds(in: myApp)
        for story in stories.items {
            let refs = story.linkedItems
            #expect(!refs.isEmpty, "Story '\(story.values["title"] ?? "?")' has no linked skill")
            for ref in refs {
                #expect(ref.componentId == "tracker-1")
                #expect(skillIds.contains(ref.itemId),
                        "Story '\(story.values["title"] ?? "?")' links to a skill id that doesn't exist")
            }
        }
    }

    @Test("Questions-to-Ask checklist is populated and isn't pre-ticked")
    func questionsChecklistIsPopulated() {
        let myApp = JobSearchExample.make()
        guard case .checklist(let data) = body(myApp, id: "checklist-1") else {
            Issue.record("checklist-1 missing or wrong kind"); return
        }
        #expect(data.items.count >= 4)
        #expect(data.items.allSatisfy { !$0.done })
        // Plain stock questions — no cross-links to other components.
        #expect(data.items.allSatisfy { $0.linkedItems.isEmpty })
    }

    @Test("Company A/B checklists cross-link every item into Experience Library or Skills")
    func companyChecklistsCrossLink() {
        let myApp = JobSearchExample.make()
        let storyIds = storyIds(in: myApp)
        let skillIds = skillIds(in: myApp)

        for checklistId in ["checklist-2", "checklist-3"] {
            guard case .checklist(let data) = body(myApp, id: checklistId) else {
                Issue.record("\(checklistId) missing or wrong kind"); continue
            }
            #expect(data.items.count >= 3, "\(checklistId) should have at least 3 expected questions")
            for item in data.items {
                #expect(!item.linkedItems.isEmpty,
                        "\(checklistId) item '\(item.text)' has no cross-link — demo loses its value")
                for ref in item.linkedItems {
                    switch ref.componentId {
                    case "tracker-1":
                        #expect(skillIds.contains(ref.itemId),
                                "\(checklistId) item '\(item.text)' links to a missing Skills row")
                    case "tracker-2":
                        #expect(storyIds.contains(ref.itemId),
                                "\(checklistId) item '\(item.text)' links to a missing Experience Library row")
                    default:
                        Issue.record("\(checklistId) item '\(item.text)' links to unexpected component \(ref.componentId)")
                    }
                }
            }
        }
    }

    @Test("Calendar events are anchored to today + N days (no past dates)")
    func calendarEventsAreEvergreen() {
        let myApp = JobSearchExample.make()
        guard case .calendar(let data) = body(myApp, id: "calendar-1") else {
            Issue.record("calendar-1 missing or wrong kind"); return
        }
        #expect(data.events.count >= 2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startOfToday = Calendar(identifier: .gregorian).startOfDay(for: Date())
        for event in data.events {
            guard let date = formatter.date(from: event.start) else {
                Issue.record("Event '\(event.title)' has unparseable ISO date: \(event.start)")
                continue
            }
            #expect(date >= startOfToday, "Event '\(event.title)' is in the past — seed dates must be relative")
        }
    }

    @Test("Slack Prep Room's #general channel references the three subagents by slug")
    func slackHasThreeAgents() {
        let myApp = JobSearchExample.make()
        guard case .slack(let data) = body(myApp, id: "slack-1") else {
            Issue.record("slack-1 missing or wrong kind"); return
        }
        // Agents are filesystem subagents (seeded AGENTS.md, checked below);
        // the channel references them by slug.
        #expect(Set(data.channels.first?.memberAgentIds ?? []) == ["coach", "challenger", "scout"])

        #expect(data.channels.count == 1)
        let general = data.channels[0]
        #expect(general.name == "general")
        #expect(Set(general.memberAgentIds) == ["coach", "challenger", "scout"])
        #expect(data.activeChannelId == general.id)
        // No seeded transcript — the user starts the conversation.
        #expect(data.messagesByChannel[general.id]?.isEmpty ?? true)
    }

    @Test("seedAgentsMd writes AGENTS.md for MyApp and every Slack agent, idempotent on second run")
    func seedAgentsMdWritesAndIsIdempotent() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-job-search-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }

        let global = MemoryStore(rootOverride: tmpBase)
        let appRoot = tmpBase.appendingPathComponent("example-job-search", isDirectory: true)

        let agentsPaths = [
            "pupa/AGENTS.md",
            "pupa/agents/coach/AGENTS.md",
            "pupa/agents/challenger/AGENTS.md",
            "pupa/agents/scout/AGENTS.md",
        ]

        // First run — all four files are absent → seeder writes all four.
        JobSearchExample.seedAgentsMd(globalMemory: global, appRoot: appRoot)
        let appMemory = MemoryStore(rootOverride: appRoot)
        for path in agentsPaths {
            #expect(appMemory.fileExists(at: path), "\(path) missing after first seed")
        }

        // Content is non-empty + carries section headers a casual reader
        // would expect — guards against silent truncation of the seed
        // strings.
        let appMd = try String(contentsOf: appRoot.appendingPathComponent("pupa/AGENTS.md"), encoding: .utf8)
        #expect(appMd.contains("Components"))
        #expect(appMd.count > 300)
        for agentSlug in ["coach", "challenger", "scout"] {
            let url = appRoot.appendingPathComponent("pupa/agents/\(agentSlug)/AGENTS.md")
            let body = try String(contentsOf: url, encoding: .utf8)
            #expect(body.contains("Persona"), "\(agentSlug)/AGENTS.md missing Persona section")
            #expect(body.count > 300, "\(agentSlug)/AGENTS.md suspiciously short")
        }

        // Second run — idempotent: doesn't throw, doesn't clobber user
        // edits. Mutate one of the files and verify it survives the
        // second seed call.
        let coachUrl = appRoot.appendingPathComponent("pupa/agents/coach/AGENTS.md")
        try "# User-edited\n".write(to: coachUrl, atomically: true, encoding: .utf8)
        JobSearchExample.seedAgentsMd(globalMemory: global, appRoot: appRoot)
        let coachAfter = try String(contentsOf: coachUrl, encoding: .utf8)
        #expect(coachAfter == "# User-edited\n", "Second seed clobbered the user edit")
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

    private func skillIds(in myApp: MyApp) -> Set<UUID> {
        guard case .tracker(let data) = body(myApp, id: "tracker-1") else { return [] }
        return Set(data.items.map(\.id))
    }

    private func storyIds(in myApp: MyApp) -> Set<UUID> {
        guard case .tracker(let data) = body(myApp, id: "tracker-2") else { return [] }
        return Set(data.items.map(\.id))
    }
}
