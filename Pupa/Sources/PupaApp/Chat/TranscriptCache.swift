import Foundation

/// One thread's persisted chat state: the rendered bubbles plus the SSE replay
/// cursor captured at the same instant, so a relaunch after an app kill can
/// reattach exactly where the cached transcript ends (pupa#103).
struct TranscriptSnapshot: Equatable, Sendable {
    var bubbles: [ChatBubble]
    /// Highest replay seq applied to `bubbles` when saved; nil when the
    /// backend never stamped one (or the save predates the cursor cache).
    var lastEventSeq: Int?
    /// True when a turn was still in flight at save time — a relaunch should
    /// catch up via reattach before treating the thread as settled.
    var turnInFlight: Bool
    var savedAt: Date
}

/// On-device cache of rendered chat transcripts, one JSON file per thread under
/// `state/transcripts/<threadId>.json`. Backend transcripts are re-fetched on
/// reopen but the backend loses threads on restart/idle; this cache lets a
/// reopened thread render its history and re-seed the agent even then.
///
/// The file is either a legacy bare `[ChatBubble]` array or a v1 snapshot
/// envelope carrying the replay cursor + in-flight flag alongside the bubbles
/// (both readable; writes always produce the envelope).
///
/// IO routes through `CloudDocument`, so files ride the existing `state/`
/// iCloud mirror. Keyed by `threadId` (globally unique across scopes).
enum TranscriptCache {

    /// On-disk envelope. Kept private — callers speak `TranscriptSnapshot`.
    private struct Envelope: Codable {
        var v: Int
        var bubbles: [ChatBubble]
        var lastEventSeq: Int?
        var turnInFlight: Bool
        var savedAt: Date
    }
    private nonisolated static var dir: URL {
        PupaStorage.stateRoot.appendingPathComponent("transcripts", isDirectory: true)
    }

    nonisolated static func url(_ threadId: String) -> URL {
        dir.appendingPathComponent("\(threadId).json")
    }

    /// Cached bubbles for `threadId`; `[]` if absent or corrupt.
    nonisolated static func load(_ threadId: String) -> [ChatBubble] {
        loadSnapshot(threadId)?.bubbles ?? []
    }

    /// Full cached snapshot for `threadId`; nil if absent or corrupt. Legacy
    /// bare-array files decode as a snapshot with no cursor and no in-flight
    /// turn.
    nonisolated static func loadSnapshot(_ threadId: String) -> TranscriptSnapshot? {
        guard let data = CloudDocument.read(url(threadId)) else { return nil }
        let dec = JSONDecoder()
        if let env = try? dec.decode(Envelope.self, from: data) {
            return TranscriptSnapshot(
                bubbles: env.bubbles, lastEventSeq: env.lastEventSeq,
                turnInFlight: env.turnInFlight, savedAt: env.savedAt)
        }
        if let bubbles = try? dec.decode([ChatBubble].self, from: data) {
            return TranscriptSnapshot(
                bubbles: bubbles, lastEventSeq: nil,
                turnInFlight: false, savedAt: .distantPast)
        }
        return nil
    }

    /// Persist `bubbles` for `threadId` with no replay cursor. Convenience for
    /// callers outside the streaming path; writes the v1 envelope.
    nonisolated static func save(_ bubbles: [ChatBubble], threadId: String) {
        save(
            TranscriptSnapshot(
                bubbles: bubbles, lastEventSeq: nil, turnInFlight: false, savedAt: Date()),
            threadId: threadId
        )
    }

    /// Persist a full snapshot for `threadId`. No-op when the bubbles are empty
    /// (never writes an empty file that would mask a real backend transcript on
    /// the next load).
    ///
    /// Inline image bytes are dropped: they serialize as base64 and this file
    /// rides the `state/` iCloud mirror uncounted by the chat-storage cap (which
    /// measures thread metadata only), so keeping them would let one image-heavy
    /// thread bloat the mirror without bound. The cache is a text-history
    /// fallback; reopened user bubbles show their text, not the thumbnail.
    nonisolated static func save(_ snapshot: TranscriptSnapshot, threadId: String) {
        guard !snapshot.bubbles.isEmpty else { return }
        let stripped = snapshot.bubbles.map { bubble -> ChatBubble in
            guard !bubble.imagesData.isEmpty else { return bubble }
            var copy = bubble
            copy.imagesData = []
            return copy
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let env = Envelope(
            v: 1, bubbles: stripped, lastEventSeq: snapshot.lastEventSeq,
            turnInFlight: snapshot.turnInFlight, savedAt: snapshot.savedAt)
        guard let data = try? enc.encode(env) else { return }
        try? CloudDocument.write(data, to: url(threadId))
    }

    /// Drop the cache file for `threadId`. Silent if already gone.
    nonisolated static func delete(_ threadId: String) {
        CloudDocument.delete(url(threadId))
    }

    /// Drop cache files for every id in `threadIds`.
    nonisolated static func delete(_ threadIds: some Sequence<String>) {
        for id in threadIds { delete(id) }
    }
}
