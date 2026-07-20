import Foundation

/// On-device cache of rendered chat transcripts, one JSON file per thread under
/// `state/transcripts/<threadId>.json`. Backend transcripts are re-fetched on
/// reopen but the backend loses threads on restart/idle; this cache lets a
/// reopened thread render its history and re-seed the agent even then.
///
/// IO routes through `CloudDocument`, so files ride the existing `state/`
/// iCloud mirror. Keyed by `threadId` (globally unique across scopes).
enum TranscriptCache {
    private nonisolated static var dir: URL {
        PupaStorage.stateRoot.appendingPathComponent("transcripts", isDirectory: true)
    }

    nonisolated static func url(_ threadId: String) -> URL {
        dir.appendingPathComponent("\(threadId).json")
    }

    /// Cached bubbles for `threadId`; `[]` if absent or corrupt.
    nonisolated static func load(_ threadId: String) -> [ChatBubble] {
        guard let data = CloudDocument.read(url(threadId)),
              let bubbles = try? JSONDecoder().decode([ChatBubble].self, from: data)
        else { return [] }
        return bubbles
    }

    /// Persist `bubbles` for `threadId`. No-op when empty (never writes an empty
    /// file that would mask a real backend transcript on the next load).
    ///
    /// Inline image bytes are dropped: they serialize as base64 and this file
    /// rides the `state/` iCloud mirror uncounted by the chat-storage cap (which
    /// measures thread metadata only), so keeping them would let one image-heavy
    /// thread bloat the mirror without bound. The cache is a text-history
    /// fallback; reopened user bubbles show their text, not the thumbnail.
    nonisolated static func save(_ bubbles: [ChatBubble], threadId: String) {
        guard !bubbles.isEmpty else { return }
        let stripped = bubbles.map { bubble -> ChatBubble in
            guard !bubble.imagesData.isEmpty else { return bubble }
            var copy = bubble
            copy.imagesData = []
            return copy
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(stripped) else { return }
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
