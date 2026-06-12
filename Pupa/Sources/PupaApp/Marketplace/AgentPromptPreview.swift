import Foundation

/// The privacy review surface shared by export and marketplace import: the
/// agent personas (name + role) that travel with a bundle as structure. Shown
/// before sharing (export screen) and before installing (marketplace detail),
/// so a user can see whose persona/prompt they're about to publish or trust.
enum AgentPromptPreview {
    /// Persona lines for the given app. When `componentIds` is non-nil, only
    /// those components are considered (export selection); nil ⇒ all.
    static func personaLines(in app: MyApp, componentIds: Set<String>? = nil) -> [String] {
        var out: [String] = []
        for comp in app.components where componentIds?.contains(comp.id) ?? true {
            if case .slack(let s) = comp.body {
                for agent in s.agents {
                    let role = agent.role.isEmpty ? "" : " — \(agent.role)"
                    out.append("\(agent.name)\(role)")
                }
            }
        }
        return out
    }
}
