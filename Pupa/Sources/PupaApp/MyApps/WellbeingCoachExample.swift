import Foundation

/// Seeded "Wellbeing Coach" MyApp.
///
/// Demonstrates deep personalisation: the agent builds bespoke
/// questionnaires as tracker rows mid-conversation, tracks mood and
/// habits over time, schedules weekly check-ins on the calendar, and
/// sends daily notification reminders for practices. Memory accumulates
/// session notes and pattern observations so the agent genuinely knows
/// the user over time.
enum WellbeingCoachExample: ExampleMyApp {
    static let name = "Wellbeing Coach"
    static let iconSystemName = "heart.text.square"
    static let tagline = "Mood log, habit tracking, personalised practices, and session check-ins — grows with you over time"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRootOverride: URL? = nil) {
        let appRoot = appRootOverride ?? MemoryStore.appRoot(myAppName: name)
        let appMemory = MemoryStore(rootOverride: appRoot)
        var wroteAny = false
        if !appMemory.fileExists(at: "pupa/AGENTS.md") {
            _ = try? appMemory.writeFile(path: "pupa/AGENTS.md", content: appAgentsMd)
            wroteAny = true
        }
        if wroteAny { globalMemory?.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        let habitWorkout = UUID()
        let habitMeditation = UUID()
        let habitReading = UUID()
        let habitGratitude = UUID()
        let habitWalk = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "heart.text.square",
                typeId: "tracker",
                components: [
                    moodLog(),
                    habitsTracker(),
                    practicesChecklist(),
                    sessionsCalendar(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        private func moodLog() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "date", label: "Date", type: .text),
                FieldDef(name: "mood", label: "Mood", type: .select,
                         options: ["Great", "Good", "Meh", "Rough", "Bad"]),
                FieldDef(name: "energy", label: "Energy", type: .select,
                         options: ["High", "Medium", "Low", "Crashed"]),
                FieldDef(name: "what_helped", label: "What helped", type: .text),
                FieldDef(name: "what_drained", label: "What drained me", type: .text),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let now = Date()
            func dayLabel(_ daysAgo: Int) -> String {
                let cal = Calendar(identifier: .gregorian)
                guard let date = cal.date(byAdding: .day, value: -daysAgo, to: now) else { return "" }
                let f = DateFormatter(); f.dateFormat = "EEE d MMM"
                return f.string(from: date)
            }
            let items: [TrackerItem] = [
                TrackerItem(values: [
                    "date": dayLabel(2),
                    "mood": "Good",
                    "energy": "Medium",
                    "what_helped": "Morning walk, got into flow on a project",
                    "what_drained": "Back-to-back calls in the afternoon",
                    "notes": "Noticed I need a buffer between calls — add 10 min gaps",
                ]),
                TrackerItem(values: [
                    "date": dayLabel(1),
                    "mood": "Meh",
                    "energy": "Low",
                    "what_helped": "Cooking dinner, reading before bed",
                    "what_drained": "Doomscrolling after dinner, poor sleep",
                    "notes": "Phone in another room at 9pm — try tomorrow",
                ]),
                TrackerItem(values: [
                    "date": dayLabel(0),
                    "mood": "Great",
                    "energy": "High",
                    "what_helped": "Good sleep, workout, deep work block in morning",
                    "what_drained": "Nothing major",
                    "notes": "Best day this week — replicate the morning structure",
                ]),
            ]
            return Component(
                id: "tracker-1",
                name: "Mood & Energy Log",
                iconSystemName: "chart.line.uptrend.xyaxis",
                body: .tracker(TrackerData(title: "Mood & Energy Log", fields: fields, items: items)),
                summary: "Daily mood and energy check-in log. Look for patterns across entries — what consistently helps or drains. The agent reads this each session to personalise its suggestions."
            )
        }

        private func habitsTracker() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "habit", label: "Habit / goal", type: .text),
                FieldDef(name: "category", label: "Category", type: .select,
                         options: ["Body", "Mind", "Sleep", "Social", "Creative", "Work"]),
                FieldDef(name: "frequency", label: "Frequency", type: .select,
                         options: ["Daily", "Weekdays", "3× week", "Weekly"]),
                FieldDef(name: "status", label: "Status", type: .select,
                         options: ["Active", "Building", "Struggling", "Paused"]),
                FieldDef(name: "streak", label: "Current streak", type: .text),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: habitWorkout, values: [
                    "habit": "Morning workout (30 min)",
                    "category": "Body",
                    "frequency": "Weekdays",
                    "status": "Active",
                    "streak": "8 days",
                    "notes": "Gym or bodyweight. Non-negotiable before 9am.",
                ]),
                TrackerItem(id: habitMeditation, values: [
                    "habit": "Meditation (10 min)",
                    "category": "Mind",
                    "frequency": "Daily",
                    "status": "Building",
                    "streak": "3 days",
                    "notes": "Using Waking Up app. Still feels forced — stick with it.",
                ]),
                TrackerItem(id: habitReading, values: [
                    "habit": "Reading (30 min before bed)",
                    "category": "Mind",
                    "frequency": "Daily",
                    "status": "Active",
                    "streak": "14 days",
                    "notes": "Non-fiction only for now. Replaces phone at night.",
                ]),
                TrackerItem(id: habitGratitude, values: [
                    "habit": "3 gratitudes (morning journal)",
                    "category": "Mind",
                    "frequency": "Daily",
                    "status": "Struggling",
                    "streak": "0 days",
                    "notes": "Keeps slipping. Try stacking it on coffee — right after pouring.",
                ]),
                TrackerItem(id: habitWalk, values: [
                    "habit": "Midday walk (20 min)",
                    "category": "Body",
                    "frequency": "Weekdays",
                    "status": "Building",
                    "streak": "2 days",
                    "notes": "Block 12:30–12:50 in calendar. Leave phone at desk.",
                ]),
            ]
            return Component(
                id: "tracker-2",
                name: "Goals & Habits",
                iconSystemName: "figure.walk",
                body: .tracker(TrackerData(title: "Goals & Habits", fields: fields, items: items)),
                summary: "Active habits and goals with status and streak. Struggling rows are the agent's first focus each session — it will suggest micro-adjustments rather than giving up on the habit."
            )
        }

        private func practicesChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(
                    text: "Morning workout (30 min) — Mon to Fri",
                    linkedItems: [ComponentItemRef(componentId: "tracker-2", itemId: habitWorkout)]
                ),
                ChecklistItem(
                    text: "Stack gratitude journal on morning coffee",
                    linkedItems: [ComponentItemRef(componentId: "tracker-2", itemId: habitGratitude)]
                ),
                ChecklistItem(
                    text: "Block 12:30–12:50 for midday walk, phone at desk",
                    linkedItems: [ComponentItemRef(componentId: "tracker-2", itemId: habitWalk)]
                ),
                ChecklistItem(text: "Phone in another room by 9pm"),
                ChecklistItem(
                    text: "Reading 30 min before bed (not phone)",
                    linkedItems: [ComponentItemRef(componentId: "tracker-2", itemId: habitReading)]
                ),
            ]
            return Component(
                id: "checklist-1",
                name: "This Week's Practices",
                iconSystemName: "checklist",
                body: .checklist(ChecklistData(title: "This Week's Practices", items: items)),
                summary: "Weekly micro-practices generated from the current Habits & Goals state. The agent rebuilds this list each session based on which habits are struggling or newly started. Cross-links point to the underlying habit rows."
            )
        }

        private func sessionsCalendar() -> Component {
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
                    title: "Weekly check-in",
                    start: iso(2, hour: 9),
                    end: iso(2, hour: 9),
                    notes: "Review the week's mood log and habit streaks with the agent. Rebuild the Practices checklist for next week."
                ),
                CalendarEvent(
                    title: "Mid-week habit check",
                    start: iso(4, hour: 8),
                    end: iso(4, hour: 8),
                    notes: "Quick 5-min check-in: which habits are slipping? What one adjustment would help?"
                ),
                CalendarEvent(
                    title: "Weekly check-in",
                    start: iso(9, hour: 9),
                    end: iso(9, hour: 9),
                    notes: "Review the week's mood log and habit streaks with the agent. Rebuild the Practices checklist for next week."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Sessions & Check-ins",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Sessions & Check-ins", events: events)),
                summary: "Scheduled wellbeing check-ins. The agent can also add exercise blocks and daily notification reminders — ask it to 'schedule a daily 8am nudge for the gratitude journal'."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension WellbeingCoachExample {
    fileprivate static let appAgentsMd = """
        # Example: Wellbeing Coach

        A demo workspace for structured self-reflection and habit building.
        The agent acts as a supportive coach — not a therapist. It reads your
        mood log and habit data each session to personalise its responses, and
        accumulates session notes in memory so it builds a picture of you over
        time.

        ## Components

        - **Mood & Energy Log** (`tracker-1`) — daily check-ins. Each row is
          one day: mood, energy, what helped, what drained, free-text notes.
          The agent reads the last 7–14 rows at session start for context.
        - **Goals & Habits** (`tracker-2`) — active habits with status
          (Active / Building / Struggling / Paused) and streak. "Struggling"
          rows are the coaching priority each session.
        - **This Week's Practices** (`checklist-1`) — a bespoke weekly
          practice list the agent regenerates based on the current habit state.
          Cross-links point back to the relevant habit rows.
        - **Sessions & Check-ins** (`calendar-1`) — scheduled reflection
          windows. The agent can also schedule daily notification nudges for
          individual habits.

        ## How to use

        Starting a session:

        1. Open Mood & Energy Log and add today's entry (or ask the agent to
           add it by answering its questions).
        2. The agent will read recent entries and habit status, then surface
           one pattern it noticed and one question to explore.
        3. Talk through whatever is on your mind — the agent guides the
           conversation, not the other way around.
        4. At the end, ask it to update the Practices checklist for the week
           and log a session note to memory.

        ## Agent behaviour

        - The agent reads `mood-log` and `habits` from the canvas each session
          without being asked — it uses this as context, not as a cue to
          narrate back what it read.
        - Session notes go into memory at `wellbeing-coach/sessions/`. The
          agent references these to track progress over time and avoid
          repeating advice that didn't land.
        - When a habit is "Struggling", the agent suggests the smallest
          possible adjustment — not abandonment. It reads the `notes` field
          for context about what's been tried.
        - Notifications: ask the agent to "remind me to meditate every morning
          at 7:30" and it will call `sendNotification`. Ask once; it
          remembers the preference in memory.

        ## What this is not

        This is a structured reflection tool, not a clinical mental health
        app. For serious mental health concerns, please work with a qualified
        professional. The agent will gently note this if a conversation moves
        into territory that requires it.
        """
}
