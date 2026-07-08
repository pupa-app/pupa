import Foundation
import Testing
@testable import PupaApp

/// Decodes the exact `GET /harnesses` wire shape the FastAPI backend emits
/// (captured live from a two-harness server) to lock the client's Codable
/// against the real contract — models, tools, and the three control types.
@Suite("BackendHarnesses decode")
struct BackendHarnessesDecodeTests {

    /// Trimmed but structurally faithful sample: one langgraph + one claude_code
    /// harness, covering `toolset` (disabled_tools), `bool`, and `choice` controls.
    private let sample = """
    [
      {
        "id": "langgraph",
        "label": "LangGraph",
        "isDefault": true,
        "models": [
          {"provider": "anthropic", "modelId": "claude-opus-4-8", "label": "Claude Opus 4.8"},
          {"provider": "openrouter", "modelId": "glm-5.1", "label": "GLM-5.1"}
        ],
        "tools": [
          {"name": "tavily_search", "description": "Web search via Tavily.", "enabledByEnv": false}
        ],
        "permissions": [
          {"key": "disabled_tools", "type": "toolset", "label": "Backend tools"},
          {"key": "shell_approval_disabled", "type": "bool", "label": "Skip shell-command approval", "default": false}
        ]
      },
      {
        "id": "claude_code",
        "label": "Claude Code",
        "isDefault": false,
        "models": [
          {"provider": "claude_code", "modelId": "opus", "label": "Opus (latest)"}
        ],
        "tools": [],
        "permissions": [
          {"key": "claude_loop_native", "type": "choice", "label": "Host tools", "options": ["off","read","edit","full"], "default": "full"},
          {"key": "claude_loop_auto_approve", "type": "bool", "label": "Run commands without asking", "default": false}
        ]
      }
    ]
    """

    @Test("decodes both harnesses with models, tools, and permission controls")
    func decodesRealShape() throws {
        let harnesses = try BackendHarnessesClient.decode(Data(sample.utf8))

        #expect(harnesses.map(\.id) == ["langgraph", "claude_code"])

        let lg = harnesses[0]
        #expect(lg.isDefault)
        // Model id is composed as "provider/modelId".
        #expect(lg.models.first?.id == "anthropic/claude-opus-4-8")
        #expect(lg.tools.first?.name == "tavily_search")
        #expect(lg.tools.first?.enabledByEnv == false)
        let shell = lg.permissions.first { $0.key == "shell_approval_disabled" }
        #expect(shell?.type == .bool)
        #expect(shell?.defaultBool == false)
        #expect(lg.permissions.first { $0.key == "disabled_tools" }?.type == .toolset)

        let cc = harnesses[1]
        #expect(!cc.isDefault)
        #expect(cc.tools.isEmpty)
        let native = cc.permissions.first { $0.key == "claude_loop_native" }
        #expect(native?.type == .choice)
        #expect(native?.options == ["off", "read", "edit", "full"])
        #expect(native?.defaultString == "full")
    }
}
