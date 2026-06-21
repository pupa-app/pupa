import Foundation
import Testing
@testable import PupaApp

@Suite("Skill frontmatter parser")
struct SkillFrontMatterTests {

    @Test("Parses fields and body from a fenced block")
    func parsesFencedBlock() {
        let raw = """
        ---
        name: deploy
        description: Deploy the app
        ---
        Run the deploy steps.
        """
        let (fields, body) = SkillFrontMatter.parse(raw)
        #expect(fields["name"] == "deploy")
        #expect(fields["description"] == "Deploy the app")
        #expect(body == "Run the deploy steps.")
    }

    @Test("No fence → whole input is the body")
    func noFence() {
        let raw = "Just a body, no frontmatter.\nSecond line."
        let (fields, body) = SkillFrontMatter.parse(raw)
        #expect(fields.isEmpty)
        #expect(body == raw)
    }

    @Test("Leading blank lines before the fence are tolerated")
    func leadingBlankLines() {
        let raw = "\n\n---\nname: x\n---\nbody"
        let (fields, body) = SkillFrontMatter.parse(raw)
        #expect(fields["name"] == "x")
        #expect(body == "body")
    }

    @Test("Unterminated fence → treated as plain body")
    func unterminatedFence() {
        let raw = "---\nname: x\nno closing fence here"
        let (fields, body) = SkillFrontMatter.parse(raw)
        #expect(fields.isEmpty)
        #expect(body == raw)
    }

    @Test("Surrounding quotes are stripped; inner colons survive")
    func quotesStripped() {
        let raw = "---\ndescription: \"Hello: world\"\nhint: 'single'\n---\nb"
        let (fields, _) = SkillFrontMatter.parse(raw)
        #expect(fields["description"] == "Hello: world")
        #expect(fields["hint"] == "single")
    }

    @Test("Bool helper reads true/false and falls back to default")
    func boolHelper() {
        let raw = "---\ndisable-model-invocation: true\nuser-invocable: false\n---\nb"
        let (fields, _) = SkillFrontMatter.parse(raw)
        #expect(SkillFrontMatter.bool(fields, "disable-model-invocation", default: false) == true)
        #expect(SkillFrontMatter.bool(fields, "user-invocable", default: true) == false)
        #expect(SkillFrontMatter.bool(fields, "missing", default: true) == true)
    }

    @Test("Duplicate keys: last wins; comments and blanks ignored")
    func dupKeysAndComments() {
        let raw = """
        ---
        # a comment
        name: first

        name: second
        ---
        body
        """
        let (fields, body) = SkillFrontMatter.parse(raw)
        #expect(fields["name"] == "second")
        #expect(body == "body")
    }

    @Test("Multi-line body keeps internal newlines, strips only leading ones")
    func bodyNewlines() {
        let raw = "---\nname: x\n---\n\nLine 1\n\nLine 2\n"
        let (_, body) = SkillFrontMatter.parse(raw)
        #expect(body == "Line 1\n\nLine 2\n")
    }
}
