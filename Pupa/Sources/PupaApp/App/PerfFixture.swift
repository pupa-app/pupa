import Foundation

/// Fixed corpus for the latency harness, so numbers compare across runs and
/// machines. Lives here rather than in PupaDemo because seeding transcripts
/// needs `TranscriptCache`, which is internal to this module.
///
/// Only ever called behind `PUPA_PERF_SEED=1`.
public enum PerfFixture {
    /// A roster wide enough for the sidebar list to cost something, each app
    /// carrying a long markdown transcript — the two things the drawer / app
    /// switch / chat-open interactions are actually paying for.
    @MainActor
    public static func seedUI(apps appCount: Int = 12, bubbles bubbleCount: Int = 60) {
        // This writes a roster and transcripts through the normal persistence
        // path, so against a real root it would create junk apps on the user's
        // device and mirror them to their other ones. Refuse unless tracing is
        // on AND storage is redirected — the two things the harness sets up.
        guard PerfTrace.isEnabled, PupaStorage.overrideRoot != nil else {
            assertionFailure("PerfFixture.seedUI called outside the perf harness")
            return
        }
        MyAppTypeRegistry.shared.registerBuiltins()
        // Built through `addMyApp`, not `MyAppStore(initial:)` — only the
        // mutating path persists, and the roster has to survive into the run
        // that measures it.
        let store = MyAppStore(initial: nil)
        for a in 0..<appCount {
            let id = store.addMyApp(
                typeId: MyAppType.tracker.id,
                name: "Perf App \(a)",
                iconSystemName: "square.grid.2x2")
            guard let app = store.myApps.first(where: { $0.id == id }) else { continue }

            var bubbles: [ChatBubble] = []
            for b in 0..<bubbleCount {
                bubbles.append(ChatBubble(
                    id: "seed-\(a)-\(b)",
                    role: b.isMultiple(of: 2) ? .user : .assistant,
                    text: """
                        ### Message \(b)

                        Some **bold** and _italic_ prose with a [link](https://example.com),
                        enough of it that parsing is not free.

                        - a list item
                        - another list item

                        ```swift
                        let x = \(b)
                        ```
                        """))
            }
            TranscriptCache.save(bubbles, threadId: app.currentThreadId)
        }
        print("[perf] seeded \(store.myApps.count) apps, \(bubbleCount) bubbles each")
    }
}
