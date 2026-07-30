import Foundation
import Testing
@testable import PupaApp

/// Tests the pure helpers backing the sidebar's create / rename sheets:
/// `MemoryFilenameHelper` (filename derivation + slugify + path join) and the
/// new `MemoryStore.fileExists` / `.folderExists` collision-detection probes
/// the sheets use before writing. UI plumbing (sheets, context menus, alerts)
/// is exercised by hand under `make mac-demo`.
@MainActor
@Suite("Memory sheets helpers")
struct MemorySheetsHelperTests {

    // MARK: - Filename resolution

    @Test("Explicit name wins and gets a .md extension appended")
    func explicitNameGetsMdSuffix() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "diet", content: "")
            == "diet.md")
        #expect(MemoryFilenameHelper.resolveFilename(name: "  workouts  ", content: "anything")
            == "workouts.md")
    }

    @Test("Explicit name with .md is kept as-is")
    func explicitNameKeepsExtension() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "notes.md", content: "")
            == "notes.md")
    }

    @Test("Explicit .json name is kept — the store allows md + json")
    func explicitNameKeepsJsonExtension() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "automations.json", content: "")
            == "automations.json")
        #expect(MemoryFilenameHelper.resolveFilename(name: "Data.JSON", content: "")
            == "Data.JSON")
    }

    @Test("Non-allowlisted extensions still get .md appended")
    func unsupportedExtensionGetsMdSuffix() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "notes.v2", content: "")
            == "notes.v2.md")
        #expect(MemoryFilenameHelper.resolveFilename(name: "run.py", content: "")
            == "run.py.md")
    }

    // MARK: - Render mode

    @Test("Only .md and extensionless files render as markdown")
    func rendersAsMarkdownByExtension() {
        #expect(MemoryFilenameHelper.rendersAsMarkdown("diet.md"))
        #expect(MemoryFilenameHelper.rendersAsMarkdown("pupa/AGENTS.MD"))
        #expect(MemoryFilenameHelper.rendersAsMarkdown("notes"))
        #expect(!MemoryFilenameHelper.rendersAsMarkdown("pupa/automations.json"))
        #expect(!MemoryFilenameHelper.rendersAsMarkdown("x.py"))
    }

    @Test("Falls back to slug derived from the first non-empty content line")
    func slugFromFirstContentLine() {
        let result = MemoryFilenameHelper.resolveFilename(
            name: "",
            content: "\n\n# My Meal Plan\nLorem ipsum dolor sit amet"
        )
        #expect(result == "my-meal-plan.md")
    }

    @Test("Strips markdown markers when deriving from first line")
    func stripsListMarkers() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "", content: "- Shopping list\n- eggs")
            == "shopping-list.md")
        #expect(MemoryFilenameHelper.resolveFilename(name: "", content: "## Header With Symbols!!!")
            == "header-with-symbols.md")
    }

    @Test("Both empty inputs yield empty filename — caller must surface an error")
    func bothEmptyMeansEmpty() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "", content: "")
            == "")
        #expect(MemoryFilenameHelper.resolveFilename(name: "   ", content: "\n\n")
            == "")
    }

    @Test("Content with only punctuation falls back to untitled.md")
    func unsluggableContentFallsBack() {
        #expect(MemoryFilenameHelper.resolveFilename(name: "", content: "!!!---***")
            == "untitled.md")
    }

    // MARK: - Slugify

    @Test("Slugify collapses whitespace and strips non-alphanumerics")
    func slugifyBasics() {
        #expect(MemoryFilenameHelper.slugify("Hello, World!") == "hello-world")
        #expect(MemoryFilenameHelper.slugify("Foo   bar    baz") == "foo-bar-baz")
        #expect(MemoryFilenameHelper.slugify("  trim me  ") == "trim-me")
    }

    @Test("Slugify caps length to maxLength")
    func slugifyLengthCap() {
        let long = String(repeating: "abcdefghij ", count: 20)
        let slug = MemoryFilenameHelper.slugify(long, maxLength: 20)
        #expect(slug.count <= 20)
        #expect(!slug.hasSuffix("-"))
    }

    // MARK: - Path join

    @Test("Path join handles root parent without leading slash")
    func joinAtRoot() {
        #expect(MemoryFilenameHelper.join(parent: "", name: "diet.md") == "diet.md")
        #expect(MemoryFilenameHelper.join(parent: "  ", name: "diet.md") == "diet.md")
    }

    @Test("Path join builds parent/leaf and trims slashes")
    func joinNested() {
        #expect(MemoryFilenameHelper.join(parent: "notes", name: "diet.md")
            == "notes/diet.md")
        #expect(MemoryFilenameHelper.join(parent: "notes/", name: "/diet.md")
            == "notes/diet.md")
    }

    // MARK: - MemoryStore collision probes

    private func makeStore() -> MemoryStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return MemoryStore(rootOverride: tmp)
    }

    @Test("fileExists is false for missing, true for written file, false for folder")
    func fileExistsBehavior() throws {
        let store = makeStore()
        #expect(store.fileExists(at: "notes/diet.md") == false)
        try store.writeFile(path: "notes/diet.md", content: "body")
        #expect(store.fileExists(at: "notes/diet.md") == true)
        #expect(store.fileExists(at: "notes") == false) // a folder, not a file
    }

    @Test("folderExists is false for missing, true for created folder, false for file")
    func folderExistsBehavior() throws {
        let store = makeStore()
        #expect(store.folderExists(at: "recipes") == false)
        try store.createFolder(path: "recipes")
        #expect(store.folderExists(at: "recipes") == true)
        try store.writeFile(path: "recipes/pasta.md", content: "x")
        #expect(store.folderExists(at: "recipes/pasta.md") == false)
    }

    @Test("Both probes reject invalid paths quietly (no throw)")
    func probesRejectInvalidPathsQuietly() {
        let store = makeStore()
        #expect(store.fileExists(at: "../escape.md") == false)
        #expect(store.folderExists(at: "../escape") == false)
    }
}
