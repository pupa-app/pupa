import Foundation

/// Seeded "Example: Dev Workspace" MyApp.
///
/// Demonstrates the shell-tool + visualisation combination: with
/// `SHELL_TOOL_ENABLED=1` the agent runs real shell commands
/// (`df`, `du`, `ps`, `brew list` etc.), populates the two tracker
/// reports with actual data, and generates a prioritised cleanup
/// checklist. Without the shell tool the example still shows the
/// component structure with representative placeholder data.
///
/// The AGENTS.md prominently explains the shell-tool requirement and
/// trust model so users understand the capability boundary.
enum DevWorkspaceExample: ExampleMyApp {
    static let name = "Example: Dev Workspace"
    static let iconSystemName = "laptopcomputer"
    static let tagline = "Laptop storage + process audit with shell access, visual kanban report, and cleanup checklist"

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
        if wroteAny { globalMemory.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        let itemDownloads = UUID()
        let itemXcodeSimulators = UUID()
        let itemNodeModules = UUID()
        let itemDockerImages = UUID()
        let itemLogs = UUID()

        let procChrome = UUID()
        let procDocker = UUID()
        let procXcode = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "laptopcomputer",
                typeId: "tracker",
                components: [
                    storageReport(),
                    processAudit(),
                    cleanupChecklist(),
                    maintenanceCalendar(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        private func storageReport() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "path", label: "Path / category", type: .text),
                FieldDef(name: "size_gb", label: "Size (GB)", type: .number),
                FieldDef(name: "type", label: "Type", type: .select,
                         options: ["Code", "Media", "Downloads", "Cache", "Backups", "Simulators", "Docker", "Logs", "Other"]),
                FieldDef(name: "last_modified", label: "Last modified", type: .text),
                FieldDef(name: "action", label: "Action", type: .select,
                         options: ["Keep", "Archive", "Delete", "Review"]),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: itemDownloads, values: [
                    "path": "~/Downloads",
                    "size_gb": "4.2",
                    "type": "Downloads",
                    "last_modified": "Today",
                    "action": "Review",
                    "notes": "Replace with live `du -sh ~/Downloads` when shell tool is on.",
                ]),
                TrackerItem(id: itemXcodeSimulators, values: [
                    "path": "~/Library/Developer/CoreSimulator",
                    "size_gb": "22.0",
                    "type": "Simulators",
                    "last_modified": "2 months ago",
                    "action": "Delete",
                    "notes": "Old iOS simulator runtimes. Run `xcrun simctl delete unavailable` to clean.",
                ]),
                TrackerItem(id: itemNodeModules, values: [
                    "path": "~/projects/**/node_modules",
                    "size_gb": "8.5",
                    "type": "Code",
                    "last_modified": "Varies",
                    "action": "Review",
                    "notes": "Find orphaned node_modules with `npx npkill`. Delete for inactive projects.",
                ]),
                TrackerItem(id: itemDockerImages, values: [
                    "path": "Docker images + volumes",
                    "size_gb": "15.3",
                    "type": "Docker",
                    "last_modified": "3 months ago",
                    "action": "Review",
                    "notes": "Run `docker system df` for breakdown. `docker image prune -a` removes unused.",
                ]),
                TrackerItem(id: itemLogs, values: [
                    "path": "~/Library/Logs",
                    "size_gb": "1.1",
                    "type": "Logs",
                    "last_modified": "Ongoing",
                    "action": "Delete",
                    "notes": "Safe to delete — system recreates log dirs on demand.",
                ]),
            ]
            var data = TrackerData(title: "Storage Report", fields: fields, items: items)
            data.viewMode = .kanban
            data.columnField = "action"
            return Component(
                id: "tracker-1",
                name: "Storage Report",
                iconSystemName: "externaldrive",
                body: .tracker(data),
                summary: "Disk usage by category, kanban-grouped by recommended action (Keep / Archive / Delete / Review). Placeholder data — ask the agent to run a live analysis when the shell tool is enabled."
            )
        }

        private func processAudit() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "name", label: "App / process", type: .text),
                FieldDef(name: "cpu_pct", label: "CPU %", type: .number),
                FieldDef(name: "mem_mb", label: "Memory (MB)", type: .number),
                FieldDef(name: "category", label: "Category", type: .select,
                         options: ["Dev tool", "Browser", "Media", "Background", "System", "Communication"]),
                FieldDef(name: "verdict", label: "Verdict", type: .select,
                         options: ["Essential", "Occasional", "Quit when idle", "Uninstall"]),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: procChrome, values: [
                    "name": "Google Chrome (14 tabs)",
                    "cpu_pct": "12",
                    "mem_mb": "1800",
                    "category": "Browser",
                    "verdict": "Essential",
                    "notes": "High memory typical. Consider Arc or tab suspension extension.",
                ]),
                TrackerItem(id: procDocker, values: [
                    "name": "Docker Desktop",
                    "cpu_pct": "4",
                    "mem_mb": "900",
                    "category": "Dev tool",
                    "verdict": "Quit when idle",
                    "notes": "Only needed during active dev. Quit it at end of day.",
                ]),
                TrackerItem(id: procXcode, values: [
                    "name": "Xcode (idle)",
                    "cpu_pct": "0",
                    "mem_mb": "2100",
                    "category": "Dev tool",
                    "verdict": "Quit when idle",
                    "notes": "Holding 2 GB idle. Quit when not actively building.",
                ]),
            ]
            return Component(
                id: "tracker-2",
                name: "App & Process Audit",
                iconSystemName: "cpu",
                body: .tracker(TrackerData(title: "App & Process Audit", fields: fields, items: items)),
                summary: "Running apps audited by CPU, memory usage, and whether they should be kept, quit when idle, or uninstalled. Agent populates with live `ps` output when shell tool is on."
            )
        }

        private func cleanupChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(
                    text: "Delete old Xcode simulator runtimes: xcrun simctl delete unavailable",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemXcodeSimulators)]
                ),
                ChecklistItem(
                    text: "Run npx npkill in ~/projects to remove orphaned node_modules",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemNodeModules)]
                ),
                ChecklistItem(
                    text: "Prune Docker images and volumes: docker system prune -a",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemDockerImages)]
                ),
                ChecklistItem(
                    text: "Empty ~/Downloads (archive anything worth keeping first)",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemDownloads)]
                ),
                ChecklistItem(
                    text: "Clear ~/Library/Logs",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemLogs)]
                ),
                ChecklistItem(
                    text: "Quit Docker Desktop and Xcode when not in use",
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-2", itemId: procDocker),
                        ComponentItemRef(componentId: "tracker-2", itemId: procXcode),
                    ]
                ),
                ChecklistItem(text: "Run Software Update — check for pending OS / app updates"),
                ChecklistItem(text: "Review login items in System Settings → General → Login Items"),
            ]
            return Component(
                id: "checklist-1",
                name: "Cleanup Actions",
                iconSystemName: "trash",
                body: .checklist(ChecklistData(title: "Cleanup Actions", items: items)),
                summary: "Concrete cleanup tasks derived from the storage and process analysis. Each item is cross-linked to the tracker row that motivated it. The agent regenerates this list after a live analysis."
            )
        }

        private func maintenanceCalendar() -> Component {
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
                    title: "Monthly disk & process audit",
                    start: iso(30, hour: 10),
                    end: iso(30, hour: 10),
                    notes: "Ask the agent to run a fresh analysis and update both tracker reports."
                ),
                CalendarEvent(
                    title: "Software Update check",
                    start: iso(7, hour: 9),
                    end: iso(7, hour: 9),
                    notes: "Check for OS and app updates. Keep Xcode and Node LTS current."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Maintenance Schedule",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Maintenance Schedule", events: events)),
                summary: "Recurring maintenance reminders. The agent can add more — ask it to 'remind me to run the disk audit every first Monday of the month'."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension DevWorkspaceExample {
    fileprivate static let appAgentsMd = """
        # Example: Dev Workspace

        A demo workspace for auditing and maintaining your laptop's storage
        and running processes. The agent can operate in two modes depending
        on whether the shell tool is enabled on the backend.

        ## Shell tool requirement

        This example is most powerful when `SHELL_TOOL_ENABLED=1` is set on
        the backend server. With the shell tool:

        - The agent runs `df -h`, `du -sh`, `ps aux`, `brew list --cask`,
          `docker system df`, `xcrun simctl list` etc. and populates the
          tracker reports with *your actual data*.
        - It generates a Cleanup Actions checklist from the real findings,
          not placeholder data.
        - It can execute safe cleanup commands (e.g. `xcrun simctl delete
          unavailable`) after summarising what it will do and getting your
          approval (if shell approval is on in Settings → Security).

        Without the shell tool, the example still shows the component
        structure and you can manually update the tracker rows based on your
        own investigation.

        **Trust model:** the shell tool gives the agent full access to your
        user shell. Only enable it on a trusted, single-user machine running
        the backend locally. Never expose a shell-enabled backend over a
        public URL without strong authentication.

        ## Components

        - **Storage Report** (`tracker-1`) — kanban by recommended action
          (Keep / Archive / Delete / Review). Each card is a path or category
          with size, type, last-modified, and cleanup notes.
        - **App & Process Audit** (`tracker-2`) — running apps and daemons
          with CPU, memory, and a verdict (Essential / Occasional / Quit when
          idle / Uninstall).
        - **Cleanup Actions** (`checklist-1`) — concrete tasks cross-linked to
          the tracker rows they address. The agent regenerates this list after
          each analysis.
        - **Maintenance Schedule** (`calendar-1`) — monthly recurring audit
          events. The agent can add specific reminders (e.g. monthly
          `docker system prune`).

        ## How to use

        Running a live analysis:

        1. Make sure `SHELL_TOOL_ENABLED=1` is set and the backend is running.
        2. Open this MyApp and type: "Analyse my laptop".
        3. The agent runs a suite of shell commands, updates both tracker
           reports with real data, and regenerates the Cleanup checklist.
        4. Work through the checklist together — the agent can run the safe
           commands (emptying caches, removing simulators) and show you the
           output before anything is deleted.
        5. Ask it to schedule the next monthly audit on the calendar.

        ## Agent behaviour

        - The agent always describes what a command will do *before* running
          it and summarises the output after.
        - Destructive operations (delete, prune) require explicit user
          confirmation in the chat, even when shell approval is off.
        - Analysis results and cleanup notes are saved to memory so the next
          session can compare against the previous state.
        """
}
