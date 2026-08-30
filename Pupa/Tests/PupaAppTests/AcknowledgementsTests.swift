import Foundation
import Testing
@testable import PupaApp

/// The Acknowledgements screen and the repo's `NOTICE.md` are two copies of one
/// fact. This suite parses the table out of `NOTICE.md` and fails when they
/// disagree, so adding a dependency to one and not the other cannot ship.
@Suite("Acknowledgements")
struct AcknowledgementsTests {

    /// One parsed row of `NOTICE.md`'s table.
    private struct NoticeRow: Equatable {
        let name: String
        let url: String
        let licence: String
        let copyright: String
        let origin: String
    }

    private struct MissingFile: Error { let name: String }

    /// Walks up from this source file to the repo root. The suite reads the
    /// real `NOTICE.md`, not a fixture — a fixture would drift too.
    private static func repoFile(_ name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw MissingFile(name: name)
    }

    /// `[name](url)` → its two halves. `nil` for any other cell, which is what
    /// skips the header and separator rows.
    private static func link(_ cell: String) -> (name: String, url: String)? {
        guard cell.hasPrefix("["), cell.hasSuffix(")"),
              let close = cell.firstIndex(of: "]"),
              let open = cell.firstIndex(of: "("),
              cell.index(after: close) == open
        else { return nil }
        return (String(cell[cell.index(after: cell.startIndex)..<close]),
                String(cell[cell.index(after: open)..<cell.index(before: cell.endIndex)]))
    }

    private static func rows(in markdown: String) -> [NoticeRow] {
        markdown.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
            let cells = trimmed.dropFirst().dropLast()
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4, let package = link(cells[0]) else { return nil }
            return NoticeRow(name: package.name, url: package.url,
                             licence: cells[1], copyright: cells[2], origin: cells[3])
        }
    }

    private static func inAppRows() -> [NoticeRow] {
        Acknowledgement.all.map {
            NoticeRow(name: $0.name, url: $0.url.absoluteString,
                      licence: $0.licence, copyright: $0.copyright, origin: $0.origin)
        }
    }

    @Test("NOTICE.md's table parses")
    func tableParses() throws {
        // Guards the parity test below from passing vacuously if the table's
        // shape ever changes and every row stops matching.
        let parsed = Self.rows(in: try Self.repoFile("NOTICE.md"))
        #expect(parsed.count == 4)
        #expect(parsed.first?.name == "swift-markdown-ui")
    }

    @Test("the in-app list matches NOTICE.md")
    func matchesNotice() throws {
        let parsed = Self.rows(in: try Self.repoFile("NOTICE.md"))
        let inApp = Self.inAppRows()
        #expect(inApp.map(\.name) == parsed.map(\.name))
        // Per row, so a mismatch names the package instead of dumping both
        // whole tables.
        for (app, notice) in zip(inApp, parsed) {
            #expect(app == notice, "\(app.name) disagrees with NOTICE.md")
        }
    }

    @Test("every entry carries its licence text")
    func licenceTextsPresent() {
        for ack in Acknowledgement.all {
            // Every MIT and BSD text ends in the same all-caps disclaimer, so
            // this catches a truncated or misassigned blob.
            #expect(ack.licenceText.contains("WARRANTIES"), "\(ack.name)")
            #expect(ack.licenceText.count > 500, "\(ack.name)")
        }
    }

    @Test("licence texts are not shared between entries")
    func licenceTextsDistinct() {
        let texts = Set(Acknowledgement.all.map(\.licenceText))
        #expect(texts.count == Acknowledgement.all.count)
    }
}
