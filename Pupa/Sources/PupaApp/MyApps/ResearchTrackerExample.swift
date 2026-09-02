import Foundation

/// Seeded "Research Tracker" MyApp.
///
/// A competitive-intelligence workspace: a Watchlist kanban of rival apps, a
/// dated Findings Log appended once per weekly sweep, a live signal-trend
/// chart over those findings, a Deltas calculator (week-over-week strong
/// signals), and a multi-agent Research Room (Scout / Analyst / Digest).
/// Ports the "parallel competitor research → comparison table" + "weekly
/// summary, what's new since last week" agent use cases. The Watchlist is
/// seeded from Pupa's own companion-app landscape so the demo is real intel,
/// not placeholder rows.
enum ResearchTrackerExample: ExampleMyApp {
    static let name = "Research Tracker"
    static let iconSystemName = "chart.line.uptrend.xyaxis.circle"
    static let tagline = "Watchlist, findings log and trend chart"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRoot: URL) {
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
        if wroteAny { globalMemory?.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        // Watchlist rows referenced by the Findings Log's linkedItems.
        let rowWebUI = UUID()
        let rowWorkspace = UUID()
        let rowIOS = UUID()
        let rowOpenClaw = UUID()
        let rowPupa = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: iconSystemName,
                typeId: "tracker",
                components: [
                    watchlist(),
                    findingsLog(),
                    signalTrend(),
                    deltas(),
                    researchRoom(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        /// `daysAgo` → "Mon 2 Jun" style label, so seeded dates track the
        /// install date instead of going stale.
        private func dayLabel(_ daysAgo: Int) -> String {
            let cal = Calendar(identifier: .gregorian)
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: Date()) else { return "" }
            let f = DateFormatter(); f.dateFormat = "EEE d MMM"
            return f.string(from: date)
        }

        // MARK: Watchlist

        private func watchlist() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "name", label: "App", type: .text),
                FieldDef(name: "platform", label: "Platform", type: .select,
                         options: ["Web", "React PWA", "Native iOS", "Native shell", "Native SwiftUI"]),
                FieldDef(name: "what_it_is", label: "What it is", type: .text),
                FieldDef(name: "assets", label: "Native structured assets?", type: .text),
                FieldDef(name: "threat", label: "Threat", type: .select,
                         options: ["Us", "Watch", "Rising", "Direct"]),
                FieldDef(name: "source_url", label: "Source", type: .text),
                FieldDef(name: "last_checked", label: "Last checked", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: rowWebUI, values: [
                    "name": "Hermes WebUI",
                    "platform": "Web",
                    "what_it_is": "Chat front-end + native org layer (sessions / tags / themes); the rest mirrors the agent.",
                    "assets": "No — org layer only, no domain assets",
                    "threat": "Watch",
                    "source_url": "github.com/nesquena/hermes-webui",
                    "last_checked": dayLabel(4),
                ]),
                TrackerItem(id: rowWorkspace, values: [
                    "name": "hermes-workspace",
                    "platform": "React PWA",
                    "what_it_is": "Chat / terminal / memory / skills / swarm. Builds no persistent visual assets.",
                    "assets": "No — pure mirror",
                    "threat": "Watch",
                    "source_url": "github.com/outsourc-e/hermes-workspace",
                    "last_checked": dayLabel(4),
                ]),
                TrackerItem(id: rowIOS, values: [
                    "name": "Hermes-iOS",
                    "platform": "Native iOS",
                    "what_it_is": "Chat + voice + sensors + widgets + Live Activities.",
                    "assets": "Status widgets only — no user-owned typed app",
                    "threat": "Rising",
                    "source_url": "github.com/dylan-buck/Hermes-iOS",
                    "last_checked": dayLabel(4),
                ]),
                TrackerItem(id: rowOpenClaw, values: [
                    "name": "OpenClaw Live Canvas",
                    "platform": "Native shell",
                    "what_it_is": "Agent draws ephemeral UIs in a WKWebView; the device adds sensors.",
                    "assets": "Ephemeral, agent-drawn — not durable or typed",
                    "threat": "Direct",
                    "source_url": "docs.openclaw.ai",
                    "last_checked": dayLabel(4),
                ]),
                TrackerItem(id: rowPupa, values: [
                    "name": "Pupa (us)",
                    "platform": "Native SwiftUI",
                    "what_it_is": "Typed persistent shapes + undo + inert .pupa export.",
                    "assets": "Yes — the only one",
                    "threat": "Us",
                    "source_url": "—",
                    "last_checked": dayLabel(0),
                ]),
            ]
            return Component(
                id: "tracker-1",
                name: "Watchlist",
                iconSystemName: "binoculars",
                body: .tracker(TrackerData(
                    title: "Watchlist",
                    fields: fields,
                    items: items,
                    viewMode: .kanban,
                    columnField: "threat"
                )),
                summary: "Companion-app landscape, kanban-grouped by threat (Us / Watch / Rising / Direct). Each card is a rival with platform, what-it-is, whether it ships native structured assets, and a source. The Findings Log links new evidence back to these rows."
            )
        }

        // MARK: Findings Log

        /// One row per piece of evidence from a weekly sweep. `subject` links
        /// back to the Watchlist row it concerns; the chart + Deltas read the
        /// `week` and `signal` columns.
        private func findingsLog() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "date", label: "Date", type: .text),
                FieldDef(name: "week", label: "Sweep", type: .select,
                         options: ["Wk 1", "Wk 2", "Wk 3"]),
                FieldDef(name: "subject", label: "Subject", type: .text),
                FieldDef(name: "signal", label: "Signal", type: .select,
                         options: ["Weak", "Notable", "Strong"]),
                FieldDef(name: "finding", label: "Finding", type: .text),
                FieldDef(name: "source", label: "Source", type: .text),
            ]
            func finding(_ daysAgo: Int, _ week: String, subject: String, ref: UUID,
                         _ signal: String, _ text: String, _ source: String) -> TrackerItem {
                TrackerItem(values: [
                    "date": dayLabel(daysAgo),
                    "week": week,
                    "subject": subject,
                    "signal": signal,
                    "finding": text,
                    "source": source,
                ], linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: ref)])
            }
            let items: [TrackerItem] = [
                finding(18, "Wk 1", subject: "Hermes-iOS", ref: rowIOS, "Strong",
                        "Shipped Live Activities + Lock-Screen widgets for long-running agent status.",
                        "GitHub release · dylan-buck/Hermes-iOS"),
                finding(17, "Wk 1", subject: "hermes-workspace", ref: rowWorkspace, "Notable",
                        "Added a swarm view for parallel subagents — still renders no persistent assets.",
                        "GitHub · outsourc-e/hermes-workspace"),
                finding(11, "Wk 2", subject: "OpenClaw", ref: rowOpenClaw, "Strong",
                        "Live Canvas now lets the agent draw charts + forms in the WKWebView (ephemeral).",
                        "docs.openclaw.ai/changelog"),
                finding(10, "Wk 2", subject: "Hermes WebUI", ref: rowWebUI, "Weak",
                        "Session tags + themes added; org layer only, no domain assets.",
                        "GitHub · nesquena/hermes-webui"),
                finding(4, "Wk 3", subject: "OpenClaw", ref: rowOpenClaw, "Strong",
                        "Device sensor nodes now feed the agent's drawn UIs — closes part of the native gap.",
                        "docs.openclaw.ai"),
                finding(3, "Wk 3", subject: "Hermes-iOS", ref: rowIOS, "Notable",
                        "Voice mode + widget refresh; assets still status-only.",
                        "GitHub · dylan-buck/Hermes-iOS"),
                finding(3, "Wk 3", subject: "hermes-workspace", ref: rowWorkspace, "Strong",
                        "Wired the agentskills.io Skills Hub — portable skills, but still no typed canvas.",
                        "GitHub · outsourc-e/hermes-workspace"),
            ]
            return Component(
                id: "tracker-2",
                name: "Findings Log",
                iconSystemName: "doc.text.magnifyingglass",
                body: .tracker(TrackerData(title: "Findings Log", fields: fields, items: items)),
                summary: "Dated evidence, one row per weekly sweep. Each finding carries a sweep week, a signal strength (Weak / Notable / Strong), and links its subject back to the Watchlist. The Signal Trend chart and Deltas calculator read this log."
            )
        }

        // MARK: Signal trend chart

        /// Trend across runs: findings per sweep week, overlaid with strong-only
        /// signals so an intensifying threat is visible. Counts the `signal`
        /// column grouped by `week` — `.count` ignores the value field.
        private func signalTrend() -> Component {
            let all = ChartSeriesSpec(
                name: "All findings",
                source: .tracker(componentId: "tracker-2", groupBy: "week",
                                 valueField: "signal", reduce: .count,
                                 filter: [:], xIsNumericOrDate: false))
            let strong = ChartSeriesSpec(
                name: "Strong signals",
                source: .tracker(componentId: "tracker-2", groupBy: "week",
                                 valueField: "signal", reduce: .count,
                                 filter: ["signal": "Strong"], xIsNumericOrDate: false))
            return Component(
                id: "chart-1",
                name: "Signal Trend",
                iconSystemName: "chart.xyaxis.line",
                body: .chart(ChartData(title: "Research signal trend", kind: .line,
                                       series: [all, strong])),
                summary: "Findings per weekly sweep, with a strong-only overlay. A rising strong-signal line means a competitor is closing the gap. Resolves live from the Findings Log — append a finding and the trend redraws."
            )
        }

        // MARK: Deltas calculator

        /// Week-over-week strong-signal delta. Each `aggregate` row counts
        /// Findings Log rows matching a filter; the formula subtracts last
        /// week's strong count from this week's.
        private func deltas() -> Component {
            func count(_ filter: [String: String]) -> CalcRowKind {
                .aggregate(AggregateSpec(sourceComponentId: "tracker-2",
                                         fieldName: "signal", reduce: .count, filter: filter))
            }
            let rows: [CalcRow] = [
                CalcRow(key: "signal_counts", name: "Signal counts (all sweeps)", kind: .header),
                CalcRow(key: "strong", name: "Strong", kind: count(["signal": "Strong"])),
                CalcRow(key: "notable", name: "Notable", kind: count(["signal": "Notable"])),
                CalcRow(key: "weak", name: "Weak", kind: count(["signal": "Weak"])),

                CalcRow(key: "wow", name: "Week over week", kind: .header),
                CalcRow(key: "strong_w2", name: "Strong signals · Wk 2", kind: count(["signal": "Strong", "week": "Wk 2"])),
                CalcRow(key: "strong_w3", name: "Strong signals · Wk 3", kind: count(["signal": "Strong", "week": "Wk 3"])),
                CalcRow(key: "new_strong", name: "Change in strong signals", format: "%+.0f",
                        kind: .formula(expression: "strong_w3 - strong_w2")),
            ]
            return Component(
                id: "calculator-1",
                name: "Deltas",
                iconSystemName: "plusminus.circle",
                body: .calculator(CalculatorData(title: "Deltas", rows: rows)),
                summary: "Counts findings by signal tier and computes the week-over-week change in strong signals. A positive 'Change in strong signals' means competitive pressure is rising this sweep. All rows resolve live from the Findings Log."
            )
        }

        // MARK: Research Room

        private func researchRoom() -> Component {
            // Agents are filesystem subagents seeded by `seedAgentsMd` at
            // `pupa/agents/<slug>/AGENTS.md`; the channel references them by slug.
            let general = SlackChannel(id: "general", name: "research", type: .channel,
                                       memberAgentIds: ["scout", "analyst", "digest"])
            return Component(
                id: "slack-1",
                name: "Research Room",
                iconSystemName: "bubble.left.and.bubble.right",
                body: .slack(SlackData(
                    channels: [general],
                    messagesByChannel: [:],
                    activeChannelId: general.id
                )),
                summary: "Multi-agent research room. @Scout finds fresh sources and releases; @Analyst scores each into Weak / Notable / Strong and appends to the Findings Log; @Digest writes the weekly 'what's new since last week' summary to memory."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension ResearchTrackerExample {
    fileprivate static var slackAgentDocs: [(slug: String, content: String)] {
        [("scout", scoutAgentsMd), ("analyst", analystAgentsMd), ("digest", digestAgentsMd)]
    }

    fileprivate static let scoutPersona = "You find fresh evidence about the apps on the Watchlist — releases, changelogs, blog posts, HN/Reddit threads. Use tavily_search or any web-fetch / RSS tool for live lookups; prefer sources < 2 weeks old and always cite the URL. Hand each find to @Analyst to score — you don't score or write summaries. Your full AGENTS.md persona lives at example-research-tracker/pupa/agents/scout/AGENTS.md."

    fileprivate static let analystPersona = "You score each find from @Scout as Weak / Notable / Strong (does it change our competitive position?), then append a row to the Findings Log (tracker-2) with the subject linked to its Watchlist row. Be specific about why a signal is strong. You don't search for sources (that's @Scout) or write the digest (that's @Digest). Your full AGENTS.md persona lives at example-research-tracker/pupa/agents/analyst/AGENTS.md."

    fileprivate static let digestPersona = "You write the weekly 'what's new since last week' summary from the latest Findings Log rows and save it to memory at research-tracker/digests/. Lead with the strongest signals and the week-over-week delta. You synthesise; you don't search (@Scout) or score (@Analyst). Your full AGENTS.md persona lives at example-research-tracker/pupa/agents/digest/AGENTS.md."

    fileprivate static let appAgentsMd = """
        # Example: Research Tracker

        A competitive-intelligence workspace. Run a weekly sweep with the
        research agents, append findings, and watch the signal trend move.
        Ships seeded with Pupa's own companion-app landscape as real intel.

        ## Components

        - **Watchlist** (`tracker-1`) — kanban of rival apps grouped by threat
          (Us / Watch / Rising / Direct). Each card carries platform, what it
          is, whether it ships native structured assets, and a source.
        - **Findings Log** (`tracker-2`) — one dated row per piece of evidence,
          tagged with a sweep week and a signal strength, linked back to its
          Watchlist row.
        - **Signal Trend** (`chart-1`) — findings per sweep with a strong-only
          overlay. Resolves live from the Findings Log.
        - **Deltas** (`calculator-1`) — signal counts + the week-over-week
          change in strong signals.
        - **Research Room** (`slack-1`) — `@Scout` finds sources, `@Analyst`
          scores + logs them, `@Digest` writes the weekly summary.

        ## How to use — the weekly sweep

        1. Open Research Room and ask `@Scout` to find what's new for the
           Watchlist apps this week (needs a search / RSS / web-fetch tool).
        2. `@Analyst` scores each find and appends it to the Findings Log with
           the subject linked to its Watchlist row.
        3. Check the Signal Trend chart and Deltas — is any competitor's strong
           signal rising?
        4. Ask `@Digest` for the "what's new since last week" summary; it saves
           to `research-tracker/digests/`.
        5. Update Watchlist threat levels if a rival's position changed.

        ## Keeping yourself updated

        - Maintain `MEMORY.md` (which sources actually pay off, recurring
          competitor patterns) and `USER.md` (the niches and rivals the user
          cares about) at this app's memory root. Keep both compact — prune
          stale lines instead of appending forever.
        - Keep a `skills/` folder. After a few sweeps, write
          `skills/weekly-sweep.md` (trigger + the exact source list + scoring
          rubric that worked). When a sweep misses something, fix that skill's
          trigger rather than starting over.
        - Each sweep, do a quick self-review: refresh `MEMORY.md`, and if you've
          learned a better scoring or sourcing convention, propose an edit to
          the relevant persona AGENTS.md.
        - Confirm in chat before overwriting a memory file or persona the user
          has edited — never clobber a user edit silently.

        ## Tips

        - The Watchlist is seeded with our real landscape — replace it with the
          competitors in your space and the whole workspace retargets.
        """

    fileprivate static let scoutAgentsMd = """
        # Scout

        **Role:** Source finder

        ## Persona

        You hunt for fresh, citable evidence about the apps on the Watchlist —
        releases, changelogs, launch posts, HN / Reddit / X threads, funding
        news.

        ## How you work

        - Use `tavily_search` or any web-fetch / RSS tool for live lookups.
          Prefer sources < 2 weeks old; always cite the URL.
        - Read the Watchlist (tracker-1) first so you search the right apps and
          don't re-surface what's already logged.
        - Hand each find to `@Analyst` with a one-line "why this might matter".

        ## What you don't do

        - You don't score signals — that's `@Analyst`.
        - You don't write the weekly summary — that's `@Digest`.
        - You don't log a finding without a source URL.
        """

    fileprivate static let analystAgentsMd = """
        # Analyst

        **Role:** Signal analyst

        ## Persona

        You decide what a find *means* for our competitive position and record
        it.

        ## How you work

        - Score each find from `@Scout`: **Strong** (changes our position /
          closes our wedge), **Notable** (worth watching), **Weak** (noise).
        - Append a row to the Findings Log (tracker-2): set `week`, `signal`,
          `finding`, `source`, and link `subject` to the right Watchlist row.
        - Say *why* a signal is strong — name the specific capability gap it
          closes.

        ## What you don't do

        - You don't search for sources — that's `@Scout`.
        - You don't write the digest — that's `@Digest`.
        - You don't inflate signals; most findings are Weak or Notable.
        """

    fileprivate static let digestAgentsMd = """
        # Digest

        **Role:** Weekly summariser

        ## Persona

        You turn the week's Findings Log into a short "what's new since last
        week" brief.

        ## How you work

        - Read the latest sweep's rows + the Deltas calculator. Lead with the
          strongest signals and the week-over-week change in strong signals.
        - Keep it tight — a few bullets, each with the subject and source.
        - Save to memory at `research-tracker/digests/` dated by sweep, so next
          week you can diff against it.

        ## What you don't do

        - You don't search (`@Scout`) or score (`@Analyst`).
        - You don't pad the summary — if nothing strong landed, say so.
        """
}
