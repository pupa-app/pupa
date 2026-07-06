import Foundation

/// Seeded "Job Search" MyApp used to onboard new users.
///
/// Demonstrates a coherent use case across every component kind plus
/// the cross-component reference graph + AGENTS.md memory layer:
///
/// - **`tracker-1` — Skills & Experience.** Inventory of skills with
///   self-rated confidence.
/// - **`tracker-2` — Experience Library.** Fleshed-out STAR stories
///   (behavioural, tech leadership, conflict, failure, initiative).
///   Each story `linkedItems` back to the skill(s) it demonstrates in
///   `tracker-1`.
/// - **`checklist-1` — Questions to Ask.** Stock questions the user
///   asks interviewers at the end of each round.
/// - **`checklist-2` / `checklist-3` — Company A / Company B expected
///   questions.** Likely interviewer questions per company, with each
///   bullet `linkedItems` cross-linked to the Experience Library story
///   that best answers it AND the underlying skill in `tracker-1`.
/// - **`calendar-1` — Interview Schedule.** Events anchored to
///   `today + N days` so the seed stays evergreen across launches.
/// - **`slack-1` — Prep Room.** Three distinct-persona agents
///   (Coach / Challenger / Scout) in a single `#general` channel.
///
/// `seedAgentsMd(globalMemory:)` writes pre-baked AGENTS.md files for
/// the MyApp and for each Slack agent so the runtime reads rich,
/// hand-tuned personas — and so the user can see the AGENTS.md feature
/// in action from the first launch. The writes are idempotent
/// (`fileExists` checked) so the function is safe to call on every
/// launch and on every restore.
enum JobSearchExample: ExampleMyApp {
    /// Display name used both as the seed's `MyApp.name` and as the
    /// idempotency key for `restoreExampleMyApp()` (a MyApp with this
    /// exact name is treated as the example workspace).
    static let name = "Job Search"
    static let iconSystemName = "briefcase"
    static let tagline = "Interview prep with cross-linked skills, stories, and a multi-agent Prep Room"

    /// Build a fresh `MyApp` populated with every demo component. Each
    /// call allocates fresh UUIDs for cross-linked items so a restored
    /// example can coexist with a hand-edited copy without colliding.
    static func make() -> MyApp {
        Builder().build()
    }

    // MARK: - AGENTS.md seeding

    /// Write the hand-tuned AGENTS.md files for the example MyApp and
    /// every Slack agent into the global memory tree. Idempotent: each
    /// file is only written if absent, so user edits survive every
    /// subsequent app launch and every Settings → "Restore example
    /// MyApp" tap.
    ///
    /// `appRootOverride` is for tests only — when nil, writes land at
    /// `MemoryStore.appRoot(myAppName: JobSearchExample.name)` under
    /// the user's ApplicationSupport tree. Passing a tmp URL lets a
    /// unit test exercise the writer without touching real memory.
    ///
    /// `@MainActor` because `MemoryStore` is main-actor-isolated;
    /// every call site is already on the main actor (`AppView.init`,
    /// `SettingsSheet` callback) so this isn't a constraint in
    /// practice.
    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRootOverride: URL? = nil) {
        let appRoot = appRootOverride ?? MemoryStore.appRoot(myAppName: name)
        let appMemory = MemoryStore(rootOverride: appRoot)
        var wroteAny = false
        if !appMemory.fileExists(at: "pupa/AGENTS.md") {
            _ = try? appMemory.writeFile(path: "pupa/AGENTS.md", content: appAgentsMd)
            wroteAny = true
        }
        for (slug, body) in slackAgentDocs {
            let path = "pupa/agents/\(slug)/AGENTS.md"
            if !appMemory.fileExists(at: path) {
                _ = try? appMemory.writeFile(path: path, content: body)
                wroteAny = true
            }
        }
        // The global store caches its tree at init; rescan so the
        // sidebar picks up the new files on next render.
        if wroteAny { globalMemory?.rescan() }
    }

    // MARK: - Builder

    /// Internal builder that pre-allocates the UUIDs of every cross-linked
    /// item so component bodies can reference each other safely. One
    /// `Builder` lifetime == one `make()` invocation.
    private struct Builder {
        // Skill rows referenced by stories.
        let skillSystemDesign = UUID()
        let skillDSA = UUID()
        let skillSTAR = UUID()
        let skillSQL = UUID()
        let skillLeadership = UUID()

        // Experience Library rows referenced by company checklists.
        let storyConflict = UUID()
        let storyMentoring = UUID()
        let storyFailure = UUID()
        let storyInitiative = UUID()
        let storyCrossFunctional = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "briefcase",
                typeId: "tracker",
                components: [
                    skillsTracker(),
                    experienceLibrary(),
                    questionsChecklist(),
                    companyAChecklist(),
                    companyBChecklist(),
                    interviewCalendar(),
                    prepRoomSlack(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        // MARK: Components

        private func skillsTracker() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "name", label: "Skill / topic", type: .text),
                FieldDef(name: "category", label: "Category", type: .select,
                         options: ["Technical", "Behavioural", "Domain", "Leadership"]),
                FieldDef(name: "confidence", label: "Confidence", type: .select,
                         options: ["Strong", "OK", "Brush up"]),
                FieldDef(name: "last_practiced", label: "Last practiced", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: skillSystemDesign, values: [
                    "name": "System design",
                    "category": "Technical",
                    "confidence": "OK",
                    "last_practiced": "2 weeks ago",
                ]),
                TrackerItem(id: skillDSA, values: [
                    "name": "Data structures & algorithms",
                    "category": "Technical",
                    "confidence": "Strong",
                    "last_practiced": "Last week",
                ]),
                TrackerItem(id: skillSTAR, values: [
                    "name": "STAR stories (behavioural)",
                    "category": "Behavioural",
                    "confidence": "OK",
                    "last_practiced": "Last month",
                ]),
                TrackerItem(id: skillSQL, values: [
                    "name": "SQL & databases",
                    "category": "Technical",
                    "confidence": "Brush up",
                    "last_practiced": "Months ago",
                ]),
                TrackerItem(id: skillLeadership, values: [
                    "name": "Tech leadership & mentoring",
                    "category": "Leadership",
                    "confidence": "Strong",
                    "last_practiced": "Ongoing",
                ]),
            ]
            return Component(
                id: "tracker-1",
                name: "Skills & Experience",
                iconSystemName: "list.bullet.rectangle",
                body: .tracker(TrackerData(
                    title: "Skills & Experience",
                    fields: fields,
                    items: items
                )),
                summary: "Inventory of skills the user is preparing for upcoming interviews. Confidence is self-rated; 'Brush up' rows flag where to focus prep time. Linked from Experience Library stories that demonstrate each skill."
            )
        }

        private func experienceLibrary() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "title", label: "Story", type: .text),
                FieldDef(name: "category", label: "Category", type: .select,
                         options: ["Behavioural", "Tech leadership", "Conflict", "Failure", "Initiative"]),
                FieldDef(name: "situation", label: "Situation", type: .text),
                FieldDef(name: "task", label: "Task", type: .text),
                FieldDef(name: "action", label: "Action", type: .text),
                FieldDef(name: "result", label: "Result", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(
                    id: storyConflict,
                    values: [
                        "title": "Disagreement on architectural direction",
                        "category": "Conflict",
                        "situation": "New revenue-reporting service was needed; team split between extending the existing monolith vs spinning out a microservice. Pressure from product to ship in 6 weeks.",
                        "task": "Drive a decision the team could commit to without one camp feeling steamrolled, and stay inside the timeline.",
                        "action": "Booked a 90-min workshop. Wrote the constraints on the board first (team capacity, deadline, on-call coverage), then asked each side to estimate effort against the constraints. The microservice camp's own estimate showed they'd miss the deadline; we converged on a modular-monolith approach with a clean boundary so we could extract later.",
                        "result": "Shipped 2 days early. Six months later we did extract the service — the boundary held, no rewrite needed. Lesson: constraints-first decisions defuse architectural arguments faster than principles-first ones.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSTAR),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSystemDesign),
                    ]
                ),
                TrackerItem(
                    id: storyMentoring,
                    values: [
                        "title": "Pulled a struggling teammate out of a slump",
                        "category": "Tech leadership",
                        "situation": "Mid-level engineer's PRs were getting bounced repeatedly; morale visibly dropping in standup; manager flagged she might be on a path to a PIP.",
                        "task": "Figure out whether the problem was skill, context, or motivation, and help her recover before the PIP conversation.",
                        "action": "Asked her to walk me through her last bounced PR. Within 10 min it was clear she hadn't internalised our review conventions because nobody had explained them — she was guessing. We paired on two PRs the same week with me narrating my review thinking out loud; I also wrote a one-pager on review heuristics for the team.",
                        "result": "Her next four PRs landed first-review. Six weeks later she was reviewing others' code. The one-pager became part of onboarding. Lesson: a struggling teammate usually lacks context, not capability — find out which before assuming.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSTAR),
                    ]
                ),
                TrackerItem(
                    id: storyFailure,
                    values: [
                        "title": "Botched a database migration",
                        "category": "Failure",
                        "situation": "Owned a column-rename migration on a 50M-row table. Locally + staging it ran in seconds; in production it locked the table for 11 minutes during business hours.",
                        "task": "Mitigate the live impact, then make sure the failure mode couldn't recur.",
                        "action": "Rolled back the migration mid-run, took the brief read-only fallout. Wrote a postmortem that named me as the responsible engineer — root cause was that staging had 1% of prod's row count, so the migration's lock time was invisible in the test. Proposed and implemented a 'shadow' migration tool that runs every migration against a copy of prod's row count.",
                        "result": "Six migrations since have run cleanly. Postmortem became a template the team still uses. Lesson: name yourself in the postmortem — owning the failure publicly is what gives you the standing to propose the fix.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSQL),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSTAR),
                    ]
                ),
                TrackerItem(
                    id: storyInitiative,
                    values: [
                        "title": "Introduced a code-review SLA",
                        "category": "Initiative",
                        "situation": "Team's PRs were stalling 3–5 days waiting for review; cycle time was the #1 retro complaint two quarters running, but nobody owned fixing it.",
                        "task": "Drive a fix without being granted authority — I was an IC, not a TL.",
                        "action": "Measured the current review latency from git data for 4 weeks and posted it as a Slack thread. Proposed a 1-business-day SLA with a rotating 'review captain' role. Asked for objections; addressed two; ran a 6-week trial with the team's consent.",
                        "result": "Median review latency went from 36h to 6h. The SLA stuck; the captain role got formalised in the team charter. Lesson: data + a finite trial + explicit consent is how an IC drives a process change without title.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                    ]
                ),
                TrackerItem(
                    id: storyCrossFunctional,
                    values: [
                        "title": "Bridged frontend and backend during a P0",
                        "category": "Tech leadership",
                        "situation": "Outage at 2am affecting checkout. Frontend on-call was blaming the API; backend on-call was blaming the client. Both were partly right and both were stuck.",
                        "task": "Unblock the diagnosis. I was the only person who'd touched both sides recently.",
                        "action": "Pulled both engineers into a single Zoom + screenshare. Asked each to demonstrate the reproducer they had. Within 10 min the actual fault surfaced — a CDN cache header that neither team owned end-to-end. Wrote a runbook entry naming the boundary explicitly so the next incident wouldn't pingpong.",
                        "result": "Outage resolved in 40 min total. Runbook caught two similar issues over the next year. Lesson: in a finger-pointing incident, the win is forcing both sides into one room with their reproducers, not adjudicating the blame.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSystemDesign),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                    ]
                ),
            ]
            return Component(
                id: "tracker-2",
                name: "Experience Library",
                iconSystemName: "books.vertical",
                body: .tracker(TrackerData(
                    title: "Experience Library",
                    fields: fields,
                    items: items
                )),
                summary: "Hand-fleshed STAR stories. Each row carries every section needed for a behavioural answer (Situation / Task / Action / Result + lesson) and links to the skill(s) it demonstrates in Skills & Experience. Company expected-question checklists link individual bullets back into this library."
            )
        }

        private func questionsChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(text: "What does success look like in this role in the first 90 days?"),
                ChecklistItem(text: "How does the team handle disagreement on technical decisions?"),
                ChecklistItem(text: "What's the on-call rotation and incident-response culture like?"),
                ChecklistItem(text: "Can you walk me through the team's current biggest challenge?"),
                ChecklistItem(text: "How is performance evaluated, and what does growth look like here?"),
            ]
            return Component(
                id: "checklist-1",
                name: "Questions to Ask",
                iconSystemName: "checklist",
                body: .checklist(ChecklistData(
                    title: "Questions to Ask",
                    items: items
                )),
                summary: "Stock interviewer questions the user asks at the end of each round. Tick off as asked per company."
            )
        }

        private func companyAChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(
                    text: "Tell me about a time you handled disagreement on a technical decision.",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyConflict),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSTAR),
                    ]
                ),
                ChecklistItem(
                    text: "How do you give feedback to a struggling teammate?",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyMentoring),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                    ]
                ),
                ChecklistItem(
                    text: "Walk me through a project that didn't go as planned.",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyFailure),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSQL),
                    ]
                ),
                ChecklistItem(
                    text: "How would you design a service to ingest 100k events/sec?",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSystemDesign),
                    ]
                ),
            ]
            return Component(
                id: "checklist-2",
                name: "Company A — Expected questions",
                iconSystemName: "questionmark.bubble",
                body: .checklist(ChecklistData(
                    title: "Company A — Expected questions",
                    items: items
                )),
                summary: "Likely interviewer questions at Company A. Each bullet is cross-linked to the Experience Library story and underlying skill that answers it — open the link pills to rehearse against the source."
            )
        }

        private func companyBChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(
                    text: "Describe a time you led a cross-functional initiative.",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyCrossFunctional),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                    ]
                ),
                ChecklistItem(
                    text: "Tell me about your worst technical decision and what you learned.",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyFailure),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillSTAR),
                    ]
                ),
                ChecklistItem(
                    text: "How do you drive process change as an IC, without authority?",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyInitiative),
                        ComponentItemRef(componentId: "tracker-1", itemId: skillLeadership),
                    ]
                ),
                ChecklistItem(
                    text: "How do you make decisions under uncertainty?",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: storyConflict),
                    ]
                ),
            ]
            return Component(
                id: "checklist-3",
                name: "Company B — Expected questions",
                iconSystemName: "questionmark.bubble",
                body: .checklist(ChecklistData(
                    title: "Company B — Expected questions",
                    items: items
                )),
                summary: "Likely interviewer questions at Company B. Cross-linked to Experience Library stories + Skills. Use to rehearse the day before the loop."
            )
        }

        private func interviewCalendar() -> Component {
            let now = Date()
            func iso(_ daysFromNow: Int, hour: Int) -> String {
                let cal = Calendar(identifier: .gregorian)
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.day = (comps.day ?? 0) + daysFromNow
                comps.hour = hour
                comps.minute = 0
                comps.second = 0
                let date = cal.date(from: comps) ?? now
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                return f.string(from: date)
            }
            let events: [CalendarEvent] = [
                CalendarEvent(
                    title: "Phone screen — Company A",
                    start: iso(3, hour: 10),
                    end: iso(3, hour: 11),
                    location: "Zoom",
                    notes: "Recruiter call — background + role overview."
                ),
                CalendarEvent(
                    title: "Technical interview — Company A",
                    start: iso(10, hour: 14),
                    end: iso(10, hour: 15),
                    location: "Zoom",
                    notes: "Coding + system design."
                ),
                CalendarEvent(
                    title: "Onsite — Company B",
                    start: iso(17, hour: 9),
                    end: iso(17, hour: 16),
                    location: "On-site",
                    notes: "Full loop: 2 coding, 1 system design, 1 behavioural."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Interview Schedule",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(
                    title: "Interview Schedule",
                    events: events
                )),
                summary: "Upcoming interview slots with companies A and B. Update as new rounds land."
            )
        }

        private func prepRoomSlack() -> Component {
            // Agents are filesystem subagents seeded by `seedAgentsMd` at
            // `pupa/agents/<slug>/AGENTS.md`; the channel references them by slug.
            let general = SlackChannel(
                id: "general",
                name: "general",
                type: .channel,
                memberAgentIds: ["coach", "challenger", "scout"]
            )
            return Component(
                id: "slack-1",
                name: "Prep Room",
                iconSystemName: "bubble.left.and.bubble.right",
                body: .slack(SlackData(
                    channels: [general],
                    messagesByChannel: [:],
                    activeChannelId: general.id
                )),
                summary: "Multi-agent prep room. @-mention Coach for mock interviews, Challenger to stress-test reasoning, or Scout to research roles and companies. Each agent's persona lives in its AGENTS.md under example-job-search/pupa/agents/<slug>/AGENTS.md."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension JobSearchExample {
    /// Per-Slack-agent AGENTS.md content, keyed by the agent's id-slug
    /// (matches the folder name produced by `slugify`). Used by
    /// `seedAgentsMd` to write each persona file at
    /// `example-job-search/pupa/agents/<slug>/AGENTS.md`.
    fileprivate static var slackAgentDocs: [(slug: String, content: String)] {
        [
            ("coach", coachAgentsMd),
            ("challenger", challengerAgentsMd),
            ("scout", scoutAgentsMd),
        ]
    }

    fileprivate static let coachPersona = "You are an experienced interview coach. Walk the user through mock interviews, help them structure STAR stories, and give constructive, concrete feedback. Be encouraging but direct about weaknesses — naming a soft spot is more useful than glossing over it. Your full AGENTS.md persona lives at example-job-search/pupa/agents/coach/AGENTS.md."

    fileprivate static let challengerPersona = "You are a sceptical, probing interviewer. Challenge the user's reasoning, push on assumptions, ask 'why?' until you reach first principles, and look for weak spots in their stories and design choices. Frame challenges as questions an interviewer would actually ask. Your full AGENTS.md persona lives at example-job-search/pupa/agents/challenger/AGENTS.md."

    fileprivate static let scoutPersona = "You help research related roles, companies, and industry context. When asked about a company or role, suggest concrete angles worth researching, common interview formats for that domain, and likely questions to prepare for. Be specific — point at what to look up, not just that the user should look something up. Your full AGENTS.md persona lives at example-job-search/pupa/agents/scout/AGENTS.md."

    fileprivate static let appAgentsMd = """
        # Example: Job Search

        A demo workspace for interview prep. Use this as a reference for the
        shape of a Pupa MyApp — chat-driven canvas, multiple linked
        components, multi-agent Slack room, persistent memory tree.

        ## Components

        - **Skills & Experience** (`tracker-1`) — inventory of skills with
          self-rated confidence. `Brush up` rows flag what to focus prep
          time on.
        - **Experience Library** (`tracker-2`) — fleshed-out STAR stories
          (behavioural, tech leadership, conflict, failure, initiative).
          Each story links back to the skill(s) it demonstrates in the
          Skills tracker.
        - **Questions to Ask** (`checklist-1`) — stock questions the user
          asks interviewers at the end of each round.
        - **Company A / B — Expected questions** (`checklist-2` /
          `checklist-3`) — likely interviewer questions per company.
          Each bullet is cross-linked to the Experience Library story
          AND the underlying skill that best answers it.
        - **Interview Schedule** (`calendar-1`) — upcoming rounds.
          Dates are anchored to `today + N days` so the demo stays
          evergreen.
        - **Prep Room** (`slack-1`) — multi-agent prep room. `@Coach` for
          mock interviews, `@Challenger` to stress-test reasoning,
          `@Scout` to research roles and companies. Each agent has its
          own AGENTS.md persona file under `pupa/agents/<agent>/AGENTS.md`.

        ## How to use

        Preparing for a specific interview round:

        1. Open the Company-X expected-questions checklist.
        2. For each bullet, follow the link pills to the Experience
           Library story it maps to; rehearse aloud.
        3. `@Coach` in the Prep Room to run a mock round, or
           `@Challenger` to stress-test the story.
        4. When a story feels shaky, walk back through its skill links
           into the Skills tracker and mark the underlying skill
           `Brush up`.

        ## Anti-patterns

        - Don't duplicate a story across multiple Experience Library
          rows — extend the existing row instead.
        - Don't add a new company-questions checklist without populating
          cross-links; the demo's value is in showing the linked graph.
        - Don't edit `AGENTS.md` files directly to debug agent behaviour
          mid-conversation — restart the chat session so the new file is
          re-read.
        """

    fileprivate static let coachAgentsMd = """
        # Coach

        **Role:** Interview prep coach

        ## Persona

        You are an experienced interview coach. Your job is to help the
        user structure prep, run mock interviews, and give constructive,
        concrete feedback. Be encouraging but direct about weaknesses —
        naming a soft spot is more useful than glossing over it.

        ## How you work

        - When the user shares a story, evaluate it against the STAR
          framework (Situation / Task / Action / Result). Call out
          missing parts explicitly.
        - Use the Experience Library tracker (`tracker-2`) as the
          reference for what a strong answer looks like. The
          cross-linked Skills tracker tells you what the user is
          currently confident in vs. needs to brush up.
        - Offer to run a mock round: ask 3–5 questions in sequence, let
          the user answer one at a time, give per-answer feedback at
          the end of each.
        - For technical questions, coach on communicating thought
          process — not just on getting the right answer.

        ## What you don't do

        - You don't research companies — that's `@Scout`'s job.
        - You don't play devil's advocate — that's `@Challenger`'s job.
        - You don't pretend a weak story is fine. Name what's missing
          and point at the source story in the Experience Library.
        """

    fileprivate static let challengerAgentsMd = """
        # Challenger

        **Role:** Devil's-advocate interviewer

        ## Persona

        You are a sceptical, probing interviewer. Your job is to
        challenge the user's reasoning, push on assumptions, ask "why?"
        until you reach first principles, and look for weak spots in
        their stories and design choices.

        ## How you work

        - Frame every challenge as a question a real interviewer would
          ask. Avoid generic "but is it really?" prompts — be specific.
        - When a story sounds rehearsed, drill into the action: "What
          did *you* do, exactly? What was someone else's contribution?"
        - For technical answers, push on trade-offs the user didn't
          mention. If they proposed solution X, ask "what breaks when
          load is 10× higher?", "what's the failure mode at 3am on a
          Sunday?".
        - Treat the Experience Library as input, not constraint — even
          a well-fleshed-out story can be probed for what was left out.

        ## What you don't do

        - You don't coach. If the user is stuck, don't soften the
          question — let `@Coach` step in.
        - You don't research roles or companies.
        - You don't pile on. One sharp question is more useful than five
          mild ones.
        """

    fileprivate static let scoutAgentsMd = """
        # Scout

        **Role:** Role & company researcher

        ## Persona

        You help the user research related roles, companies, and
        industry context. You're the "go find out" agent — when the
        user mentions a company name or a job spec, you spin up
        concrete research angles instead of giving generic
        "you should research" non-advice.

        ## How you work

        - When asked about a company: suggest 3–5 specific angles worth
          checking (recent product launches, public on-call posts,
          engineering blog, Glassdoor patterns, engineering podcasts
          they've appeared on, GitHub orgs).
        - When asked about a role: list common interview formats for
          that domain, the kinds of questions you'd expect, and the
          company-specific quirks worth Googling.
        - Pull from the user's Skills tracker — if they're weak in
          something the role expects, flag it explicitly with the
          skill row id so it's easy to navigate.
        - When the user wants to dig deeper, offer to use the
          `tavily_search` tool to fetch live information.

        ## What you don't do

        - You don't coach or run mock interviews — you're upstream of
          that.
        - You don't speculate about specific salary ranges without
          sources.
        - You don't write the cover letter — that's the user's voice,
          not yours.
        """
}
