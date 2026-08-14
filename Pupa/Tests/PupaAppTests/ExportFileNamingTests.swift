import Foundation
import Testing
@testable import PupaApp

/// File base name for an exported `.pupa` — must never be empty, or the
/// bundle escapes its temp folder and the save panel gets a junk name.
@MainActor
@Suite("Export file naming")
struct ExportFileNamingTests {

    @Test("Ordinary names slugify")
    func slugifiesName() {
        #expect(MyAppExporter.exportBaseName(forAppName: "Habit Tracker") == "habit-tracker")
    }

    @Test("Names that slugify to nothing fall back")
    func fallsBackWhenSlugEmpty() {
        for name in ["🚀🚀", "", "!!!", "   "] {
            #expect(MyAppExporter.exportBaseName(forAppName: name) == "pupa-app")
        }
    }
}
