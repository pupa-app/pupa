import Foundation

/// Seeded "Daily Briefing" MyApp.
///
/// A morning-briefing workspace: a Briefing Sources tracker naming the MCP /
/// skill each feed uses, a Today's Briefing card list the agent rewrites each
/// morning, a Briefing History tracker feeding a feed-volume trend chart, and
/// a Schedule calendar carrying the recurring 7am push + the day's events.
/// Ports the "every morning at 7am: weather + calendar + top-5 HN AI posts +
/// GitHub notifications, < 500 words" agent use case. Assumes the backend has
/// weather / calendar / GitHub / HN / RSS tools; the Sources tracker makes
/// that dependency explicit and degrades a source to Off when its tool is
/// absent.
enum DailyBriefingExample: ExampleMyApp {
    static let name = "Daily Briefing"
    static let iconSystemName = "sun.horizon"
    static let tagline = "Weather, agenda and news, pushed every morning"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRoot: URL) {
        let appMemory = MemoryStore(rootOverride: appRoot)
        if !appMemory.fileExists(at: "pupa/AGENTS.md") {
            _ = try? appMemory.writeFile(path: "pupa/AGENTS.md", content: appAgentsMd)
            globalMemory?.rescan()
        }
    }

    // MARK: - Builder

    private struct Builder {
        // Source rows referenced by Today's Briefing's linkedItems.
        let srcWeather = UUID()
        let srcCalendar = UUID()
        let srcHN = UUID()
        let srcGitHub = UUID()
        let srcMarkets = UUID()
        let srcRSS = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: iconSystemName,
                typeId: "tracker",
                components: [
                    sources(),
                    todaysBriefing(),
                    history(),
                    volumeTrend(),
                    schedule(),
                ],
                activeComponentId: "tracker-2"
            )
        }

        // MARK: Briefing Sources

        private func sources() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "source", label: "Source", type: .text),
                FieldDef(name: "tool", label: "Tool / MCP", type: .text),
                FieldDef(name: "cadence", label: "Cadence", type: .select,
                         options: ["Daily", "Weekdays", "Hourly"]),
                FieldDef(name: "enabled", label: "Enabled", type: .select,
                         options: ["On", "Off"]),
                FieldDef(name: "last_pulled", label: "Last pulled", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: srcWeather, values: [
                    "source": "Weather", "tool": "weather MCP (forecast)",
                    "cadence": "Daily", "enabled": "On", "last_pulled": "Today 07:00",
                ]),
                TrackerItem(id: srcCalendar, values: [
                    "source": "Calendar", "tool": "calendar MCP / EventKit",
                    "cadence": "Daily", "enabled": "On", "last_pulled": "Today 07:00",
                ]),
                TrackerItem(id: srcHN, values: [
                    "source": "Hacker News (AI)", "tool": "tavily_search / HN API",
                    "cadence": "Daily", "enabled": "On", "last_pulled": "Today 07:00",
                ]),
                TrackerItem(id: srcGitHub, values: [
                    "source": "GitHub notifications", "tool": "github MCP",
                    "cadence": "Weekdays", "enabled": "On", "last_pulled": "Today 07:00",
                ]),
                TrackerItem(id: srcMarkets, values: [
                    "source": "Markets", "tool": "markets MCP (quotes)",
                    "cadence": "Weekdays", "enabled": "Off", "last_pulled": "—",
                ]),
                TrackerItem(id: srcRSS, values: [
                    "source": "Newsletters (RSS)", "tool": "rss tool",
                    "cadence": "Daily", "enabled": "On", "last_pulled": "Today 07:00",
                ]),
            ]
            return Component(
                id: "tracker-1",
                name: "Briefing Sources",
                iconSystemName: "antenna.radiowaves.left.and.right",
                body: .tracker(TrackerData(title: "Briefing Sources", fields: fields, items: items)),
                summary: "The feeds the morning briefing pulls, each naming the tool / MCP it uses. Flip a source On / Off to add or drop a section. Markets is Off — turn it On once a markets MCP is configured on the backend."
            )
        }

        // MARK: Today's Briefing

        /// One row per briefing section. `source` links the Briefing Sources
        /// row that produced it, so a section traces back to its feed.
        private func todaysBriefing() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "section", label: "Section", type: .text),
                FieldDef(name: "summary", label: "Summary", type: .text),
                FieldDef(name: "priority", label: "Priority", type: .select,
                         options: ["Now", "Today", "FYI"]),
            ]
            func section(_ title: String, _ summary: String, _ priority: String, src: UUID?) -> TrackerItem {
                TrackerItem(
                    values: ["section": title, "summary": summary, "priority": priority],
                    linkedItems: src.map { [ComponentItemRef(componentId: "tracker-1", itemId: $0)] } ?? []
                )
            }
            let items: [TrackerItem] = [
                section("Weather",
                        "Clear, high 24°C, light breeze. No rain — good for the 6pm run.",
                        "Today", src: srcWeather),
                section("Today's agenda",
                        "3 meetings: 10:00 standup, 13:00 design review, 16:00 1:1. Free 11:00–13:00 for deep work.",
                        "Now", src: srcCalendar),
                section("Top AI on HN",
                        "1) New open-weights 70B tops prior SOTA on SWE-bench. 2) 'The harness beats the model' essay. 3) MCP registry passes 1k servers.",
                        "Today", src: srcHN),
                section("GitHub",
                        "4 review requests, CI failing on the pupa#54 branch, 1 mention in pupa-backend.",
                        "Now", src: srcGitHub),
                section("One thing to focus on",
                        "Ship the Research Tracker template — it unblocks the marketplace demo.",
                        "Now", src: nil),
            ]
            return Component(
                id: "tracker-2",
                name: "Today's Briefing",
                iconSystemName: "newspaper",
                body: .tracker(TrackerData(title: "Today's Briefing", fields: fields, items: items)),
                summary: "The morning brief, one card per section, kept under ~500 words total. The agent rewrites these rows each morning from the enabled sources; each section links back to the feed that produced it."
            )
        }

        // MARK: Briefing History

        /// Per-weekday feed volume, the data behind the trend chart. `day` is
        /// index-prefixed so the chart's x-axis stays Mon→Fri.
        private func history() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "day", label: "Day", type: .select,
                         options: ["1 Mon", "2 Tue", "3 Wed", "4 Thu", "5 Fri"]),
                FieldDef(name: "hn_count", label: "HN AI posts", type: .number),
                FieldDef(name: "github_count", label: "GitHub notifs", type: .number),
                FieldDef(name: "focus_done", label: "Focus done", type: .select,
                         options: ["Yes", "No"]),
            ]
            func row(_ day: String, _ hn: Int, _ gh: Int, _ focus: String) -> TrackerItem {
                TrackerItem(values: [
                    "day": day, "hn_count": String(hn),
                    "github_count": String(gh), "focus_done": focus,
                ])
            }
            let items: [TrackerItem] = [
                row("1 Mon", 5, 6, "No"),
                row("2 Tue", 4, 9, "Yes"),
                row("3 Wed", 6, 4, "Yes"),
                row("4 Thu", 5, 11, "No"),
                row("5 Fri", 3, 5, "Yes"),
            ]
            return Component(
                id: "tracker-3",
                name: "Briefing History",
                iconSystemName: "calendar.day.timeline.left",
                body: .tracker(TrackerData(title: "Briefing History", fields: fields, items: items)),
                summary: "One row per day logging feed volume (HN AI posts, GitHub notifications) and whether the day's focus item got done. The agent appends a row each morning; the Feed Volume chart plots it."
            )
        }

        // MARK: Feed Volume chart

        private func volumeTrend() -> Component {
            let hn = ChartSeriesSpec(
                name: "HN AI posts",
                source: .tracker(componentId: "tracker-3", groupBy: "day",
                                 valueField: "hn_count", reduce: .sum,
                                 filter: [:], xIsNumericOrDate: false))
            let gh = ChartSeriesSpec(
                name: "GitHub notifs",
                source: .tracker(componentId: "tracker-3", groupBy: "day",
                                 valueField: "github_count", reduce: .sum,
                                 filter: [:], xIsNumericOrDate: false))
            return Component(
                id: "chart-1",
                name: "Feed Volume",
                iconSystemName: "chart.bar.xaxis",
                body: .chart(ChartData(title: "Feed volume this week", kind: .bar,
                                       series: [hn, gh])),
                summary: "Daily feed volume across the week, resolved live from Briefing History. A spike in GitHub notifications is a cue to protect deep-work time the next morning."
            )
        }

        // MARK: Schedule

        private func schedule() -> Component {
            func iso(_ daysFromNow: Int, hour: Int) -> String {
                let cal = Calendar(identifier: .gregorian)
                var comps = cal.dateComponents([.year, .month, .day], from: Date())
                comps.day = (comps.day ?? 0) + daysFromNow
                comps.hour = hour; comps.minute = 0; comps.second = 0
                let date = cal.date(from: comps) ?? Date()
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
                return f.string(from: date)
            }
            let events: [CalendarEvent] = [
                CalendarEvent(
                    title: "Daily Briefing",
                    start: iso(1, hour: 7), end: iso(1, hour: 7),
                    notes: "Your 7am push. Ask the agent to 'send my briefing every morning at 7' and it schedules a daily sendNotification."),
                CalendarEvent(title: "Standup", start: iso(0, hour: 10), end: iso(0, hour: 10),
                              notes: "Team standup."),
                CalendarEvent(title: "Design review", start: iso(0, hour: 13), end: iso(0, hour: 14),
                              notes: "Marketplace template review."),
                CalendarEvent(title: "1:1", start: iso(0, hour: 16), end: iso(0, hour: 16),
                              notes: "Weekly 1:1."),
                CalendarEvent(title: "Evening run", start: iso(0, hour: 18), end: iso(0, hour: 18),
                              notes: "5k — weather's clear per today's briefing."),
            ]
            return Component(
                id: "calendar-1",
                name: "Schedule",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Schedule", events: events)),
                summary: "The recurring 7am briefing push plus today's events (pulled into the briefing's agenda section). Ask the agent to schedule the daily notification once; it remembers the preference."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension DailyBriefingExample {
    fileprivate static let appAgentsMd = """
        # Example: Daily Briefing

        A morning-briefing workspace. The agent pulls a handful of feeds, writes
        a tight brief, and pushes it at 7am.

        ## Components

        - **Briefing Sources** (`tracker-1`) — the feeds, each naming the tool /
          MCP it uses and whether it's On. This is the capability contract: a
          source only works if its tool is configured on the backend.
        - **Today's Briefing** (`tracker-2`) — one card per section, kept under
          ~500 words total. Each section links back to its source.
        - **Briefing History** (`tracker-3`) — per-day feed volume + whether the
          focus item got done.
        - **Feed Volume** (`chart-1`) — the week's feed volume, live from
          Briefing History.
        - **Schedule** (`calendar-1`) — the recurring 7am push + today's events.

        ## How to use — the morning loop

        1. For each **On** source, pull fresh data with its named tool (weather
           MCP, calendar, HN, GitHub, RSS). Skip a source whose tool is missing.
        2. Rewrite the Today's Briefing rows — lead with `Now` items, keep the
           whole thing under ~500 words, link each section to its source.
        3. Append a Briefing History row (HN + GitHub counts, focus done?) so the
           Feed Volume chart updates.
        4. Send the brief as a notification. To automate it: ask "send my
           briefing every morning at 7" — the agent schedules a daily
           `sendNotification`.

        ## Capability boundaries

        - A source needs its tool on the backend. **Markets** ships Off because
          no markets MCP is assumed — turn it On once one is configured.
        - If a tool fails, mark its source's `last_pulled` and note the gap in
          the brief rather than inventing data.

        ## Keeping yourself updated

        - Maintain `MEMORY.md` (which sources are noisy vs. useful, recurring
          themes) and `USER.md` (which sections the user actually reads, their
          tone + length preference) at this app's memory root. Keep both
          compact — prune rather than append forever.
        - Keep a `skills/` folder: write `skills/morning-brief.md` (the source
          order + length that landed well). When a feed dies or a section gets
          ignored, fix that skill's trigger — drop the dead source, reorder the
          sections the user reads first.
        - Each morning, glance at `USER.md` before writing: reorder and trim to
          what the user reads. Record a skipped-source failure so you stop
          re-pulling a dead feed.
        - Confirm in chat before overwriting a memory file the user has edited.
        """
}
