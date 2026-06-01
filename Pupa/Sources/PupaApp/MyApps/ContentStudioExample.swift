import Foundation

/// Seeded "Example: Content Studio" MyApp.
///
/// Demonstrates a personal editorial pipeline: ideas flow through a
/// kanban from Idea → Published, a Publish Checklist keeps quality
/// consistent, a Publishing Calendar shows upcoming deadlines, and a
/// multi-agent Studio Room (Researcher / Editor / Ideator) helps produce
/// content. Showcases kanban view mode + local notifications as
/// publish-day reminders.
enum ContentStudioExample: ExampleMyApp {
    static let name = "Example: Content Studio"
    static let iconSystemName = "square.and.pencil"
    static let tagline = "Editorial pipeline — kanban board, publish checklist, calendar, and multi-agent Studio Room"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore, appRootOverride: URL? = nil) {
        let appRoot = appRootOverride ?? MemoryStore.appRoot(myAppName: name)
        let appMemory = MemoryStore(rootOverride: appRoot)
        var wroteAny = false
        if !appMemory.fileExists(at: "AGENTS.md") {
            _ = try? appMemory.writeFile(path: "AGENTS.md", content: appAgentsMd)
            wroteAny = true
        }
        for (slug, body) in slackAgentDocs {
            let path = "slack/\(slug)/AGENTS.md"
            if !appMemory.fileExists(at: path) {
                _ = try? appMemory.writeFile(path: path, content: body)
                wroteAny = true
            }
        }
        if wroteAny { globalMemory.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        let itemAIAgents = UUID()
        let itemRemoteWork = UUID()
        let itemProductivity = UUID()
        let itemDeepWork = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "square.and.pencil",
                typeId: "tracker",
                components: [
                    contentPipeline(),
                    publishChecklist(),
                    publishingCalendar(),
                    studioRoom(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        private func contentPipeline() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "title", label: "Title / working headline", type: .text),
                FieldDef(name: "format", label: "Format", type: .select,
                         options: ["Thread", "Long post", "Newsletter", "Short video", "Article"]),
                FieldDef(name: "platform", label: "Platform", type: .select,
                         options: ["LinkedIn", "Twitter / X", "Substack", "YouTube", "Blog"]),
                FieldDef(name: "stage", label: "Stage", type: .select,
                         options: ["Idea", "Research", "Draft", "Review", "Scheduled", "Published"]),
                FieldDef(name: "publish_date", label: "Publish date", type: .text),
                FieldDef(name: "notes", label: "Notes / angle", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: itemAIAgents, values: [
                    "title": "How I use AI agents to double my content output",
                    "format": "Thread",
                    "platform": "Twitter / X",
                    "stage": "Draft",
                    "publish_date": "This Thursday",
                    "notes": "Personal workflow — show before/after time breakdown. @Researcher to pull stats on AI tool adoption.",
                ]),
                TrackerItem(id: itemRemoteWork, values: [
                    "title": "5 remote-work habits that actually stuck after 3 years",
                    "format": "Long post",
                    "platform": "LinkedIn",
                    "stage": "Review",
                    "publish_date": "Monday",
                    "notes": "Draw from personal experience. Strong hook needed — @Editor review.",
                ]),
                TrackerItem(id: itemProductivity, values: [
                    "title": "The productivity tool graveyard",
                    "format": "Newsletter",
                    "platform": "Substack",
                    "stage": "Idea",
                    "publish_date": "",
                    "notes": "Tools I tried and abandoned and why. Self-deprecating angle works well for this audience.",
                ]),
                TrackerItem(id: itemDeepWork, values: [
                    "title": "Deep work is dead — and that's okay",
                    "format": "Article",
                    "platform": "Blog",
                    "stage": "Research",
                    "publish_date": "Next week",
                    "notes": "Counter-narrative piece. @Researcher pull recent data on attention spans + Cal Newport rebuttals.",
                ]),
            ]
            var data = TrackerData(title: "Content Pipeline", fields: fields, items: items)
            data.viewMode = .kanban
            data.columnField = "stage"
            return Component(
                id: "tracker-1",
                name: "Content Pipeline",
                iconSystemName: "rectangle.stack",
                body: .tracker(data),
                summary: "Editorial kanban. Columns are stages (Idea → Published). Each card carries format, platform, publish date, and a notes/angle field. @Researcher is the go-to for research; @Editor reviews before scheduling."
            )
        }

        private func publishChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(text: "Headline passes the 'would I click this?' test"),
                ChecklistItem(text: "Opening hook lands in ≤ 2 sentences"),
                ChecklistItem(text: "CTA is clear and placed at the end"),
                ChecklistItem(text: "Images / graphics attached and correctly sized"),
                ChecklistItem(text: "Links checked — no broken or placeholder URLs"),
                ChecklistItem(text: "Hashtags / tags reviewed for relevance"),
                ChecklistItem(text: "Scheduled in publishing tool (Buffer / Later / native)"),
                ChecklistItem(text: "Notification set for day-of reminder"),
            ]
            return Component(
                id: "checklist-1",
                name: "Publish Checklist",
                iconSystemName: "checklist",
                body: .checklist(ChecklistData(title: "Publish Checklist", items: items)),
                summary: "Reusable pre-publish review. Tick each item before a piece goes live. Reset between pieces."
            )
        }

        private func publishingCalendar() -> Component {
            let now = Date()
            func iso(_ daysFromNow: Int, hour: Int) -> String {
                let cal = Calendar(identifier: .gregorian)
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.day = (comps.day ?? 0) + daysFromNow
                comps.hour = hour; comps.minute = 0; comps.second = 0
                let date = cal.date(from: comps) ?? now
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
                return f.string(from: date)
            }
            let events: [CalendarEvent] = [
                CalendarEvent(
                    title: "Publish — Remote work habits (LinkedIn)",
                    start: iso(1, hour: 9),
                    end: iso(1, hour: 9),
                    notes: "Monday morning slot — peak LinkedIn engagement. Final check before posting.",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemRemoteWork)]
                ),
                CalendarEvent(
                    title: "Publish — AI agents thread (Twitter/X)",
                    start: iso(3, hour: 8),
                    end: iso(3, hour: 8),
                    notes: "Thursday 8am — best engagement window for tech threads.",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemAIAgents)]
                ),
                CalendarEvent(
                    title: "Content planning session",
                    start: iso(7, hour: 10),
                    end: iso(7, hour: 11),
                    notes: "Weekly planning: review pipeline, pick next Idea to move to Research, brainstorm with @Ideator."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Publishing Calendar",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Publishing Calendar", events: events)),
                summary: "Scheduled publish slots and planning sessions. Calendar events are cross-linked to the pipeline items they correspond to."
            )
        }

        private func studioRoom() -> Component {
            let researcher = SlackAgent(
                id: "researcher",
                name: "Researcher",
                role: "Content researcher",
                systemPromptAddition: researcherPersona
            )
            let editor = SlackAgent(
                id: "editor",
                name: "Editor",
                role: "Editorial coach",
                systemPromptAddition: editorPersona
            )
            let ideator = SlackAgent(
                id: "ideator",
                name: "Ideator",
                role: "Creative angle generator",
                systemPromptAddition: ideatorPersona
            )
            let general = SlackChannel(
                id: "general",
                name: "general",
                type: .channel,
                memberAgentIds: [researcher.id, editor.id, ideator.id]
            )
            return Component(
                id: "slack-1",
                name: "Studio Room",
                iconSystemName: "bubble.left.and.bubble.right",
                body: .slack(SlackData(
                    agents: [researcher, editor, ideator],
                    channels: [general],
                    messagesByChannel: [:],
                    activeChannelId: general.id
                )),
                summary: "Multi-agent editorial room. @Researcher fetches live facts and data; @Editor tightens structure, hooks, and CTAs; @Ideator brainstorms fresh angles and formats."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension ContentStudioExample {
    fileprivate static var slackAgentDocs: [(slug: String, content: String)] {
        [("researcher", researcherAgentsMd), ("editor", editorAgentsMd), ("ideator", ideatorAgentsMd)]
    }

    fileprivate static let researcherPersona = "You research facts, data, and context to support content creation. When asked about a topic, pull statistics, recent trends, counter-narratives, and notable voices worth citing. If tavily_search is available, use it for live web lookups. Be specific — point at concrete data, not vague advice to 'do more research'. Your full AGENTS.md persona lives at example-content-studio/slack/researcher/AGENTS.md."

    fileprivate static let editorPersona = "You are an editorial coach who reviews content for clarity, structure, and impact. When shown a draft, assess the hook, body flow, and CTA. Give line-level feedback — rewrite weak sentences directly, don't just describe what's wrong. Push for specificity and remove filler. Your full AGENTS.md persona lives at example-content-studio/slack/editor/AGENTS.md."

    fileprivate static let ideatorPersona = "You generate creative angles, formats, and content ideas. When given a topic, suggest 3–5 distinct angles — contrarian, personal story, listicle, data-driven, Q&A — with a one-line hook for each. Think about what would make someone stop scrolling. Your full AGENTS.md persona lives at example-content-studio/slack/ideator/AGENTS.md."

    fileprivate static let appAgentsMd = """
        # Example: Content Studio

        A demo workspace for managing a personal content pipeline. Chat with
        the agent to move content through stages, schedule pieces, and work
        with the studio agents on research, editing, and ideation.

        ## Components

        - **Content Pipeline** (`tracker-1`) — kanban board. Each card is a
          piece of content with format, platform, stage (Idea → Published),
          publish date, and notes. Move cards by asking the agent to change
          the stage field.
        - **Publish Checklist** (`checklist-1`) — reusable pre-publish review.
          Reset it between pieces; the agent can tick items as you work through
          them together.
        - **Publishing Calendar** (`calendar-1`) — scheduled publish slots and
          planning sessions. Events are cross-linked to pipeline cards so you
          can navigate from calendar → content card in one tap.
        - **Studio Room** (`slack-1`) — three-agent room. Use `@Researcher`
          for live data and facts, `@Editor` for line-level draft feedback, and
          `@Ideator` to brainstorm fresh angles.

        ## How to use

        Moving a piece from idea to published:

        1. Ask the agent to add a new idea to the Content Pipeline. Describe
           the topic and platform — the agent picks format and stage.
        2. Go to Studio Room, `@Ideator` for 3–5 angle variants; pick one and
           ask the agent to update the pipeline card's notes field.
        3. `@Researcher` for facts and data to back up the angle.
        4. Draft the piece. When ready, paste the draft into chat and ask
           `@Editor` to review. Iterate.
        5. Ask the agent to move the card to "Scheduled" and add a calendar
           event with a publish-day notification.
        6. On publish day, run through the Publish Checklist together, then
           move the card to "Published".

        ## Tips

        - Notifications: ask the agent to "remind me an hour before each
          publish slot" — it will call `sendNotification` for each calendar
          event linked to a scheduled card.
        - Memory: tell the agent your brand voice, target audience, and
          content pillars once — it will write them to memory and apply them
          every session.
        """

    fileprivate static let researcherAgentsMd = """
        # Researcher

        **Role:** Content researcher

        ## Persona

        You find the facts, data, and context that make content credible and
        specific. Your job is to give the creator concrete material — not to
        write the content itself.

        ## How you work

        - When asked about a topic, surface: recent statistics, counter-
          narratives, notable practitioners worth citing, and anything
          surprising that would make a reader stop scrolling.
        - If `tavily_search` is available, use it to pull live data. Prefer
          recent sources (< 12 months). Always note the source so the creator
          can link or attribute.
        - Look at the Content Pipeline tracker for context about the piece's
          angle before you start researching — the notes field often tells you
          what kind of data is needed.
        - Give 3–5 concrete data points, not a wall of text. Quality over
          quantity.

        ## What you don't do

        - You don't write the content — that's the creator's voice.
        - You don't give style or structure advice — that's `@Editor`.
        - You don't speculate without noting it as speculation.
        """

    fileprivate static let editorAgentsMd = """
        # Editor

        **Role:** Editorial coach

        ## Persona

        You review content for clarity, structure, and impact. You give direct,
        specific feedback — rewriting weak sentences rather than describing
        what's wrong with them.

        ## How you work

        - **Hook first.** Does the opening sentence make you want to keep
          reading? If not, rewrite it — show the creator 2–3 alternatives.
        - **Structure.** Does the piece flow? Where does the reader's attention
          drop? Name the paragraph, not just "it loses momentum".
        - **CTA.** Is there one? Is it clear? Is it placed where it'll be seen?
        - **Specificity.** Flag vague sentences ("this is important",
          "many people") and ask for the specific fact or story behind them.
        - **Trim.** Identify the 20% that could be cut without losing meaning.

        ## What you don't do

        - You don't research or add new content — that's `@Researcher`.
        - You don't generate new ideas — that's `@Ideator`.
        - You don't flatten the creator's voice to generic corporate copy.
        """

    fileprivate static let ideatorAgentsMd = """
        # Ideator

        **Role:** Creative angle generator

        ## Persona

        You help find the angle that will make a piece of content stand out.
        You think in hooks, contrasts, and surprising framings.

        ## How you work

        - When given a topic, suggest 3–5 distinct angles:
          - **Contrarian** — argue the opposite of the conventional wisdom.
          - **Personal story** — what's the creator's lived experience here?
          - **Data-first** — lead with a surprising statistic.
          - **Listicle** — structured, scannable, shareable.
          - **Q&A / myth-bust** — address the question everyone is afraid to ask.
        - For each angle, write a one-line hook — the first sentence that would
          stop someone scrolling.
        - Ask about the platform and audience before suggesting — a LinkedIn
          angle is different from a Twitter thread angle.

        ## What you don't do

        - You don't write the full piece — you hand off to the creator.
        - You don't critique drafts — that's `@Editor`.
        - You don't research the facts behind the ideas — that's `@Researcher`.
        """
}
