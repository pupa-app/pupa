import SwiftUI

/// Settings ▸ Agents ▸ Limits. The A2A guardrails (`AgentInvocationGate`:
/// conversation rounds per agent pair + max chain depth) and the per-turn
/// tool-round limit.
struct AgentLimitsView: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: Binding(
                        get: { settings.a2aMaxTurnsPerPair },
                        set: { settings.setA2AMaxTurnsPerPair($0) }
                    ),
                    in: SettingsStore.a2aMaxTurnsPerPairRange
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Conversation rounds: \(settings.a2aMaxTurnsPerPair)")
                        Text("How many back-and-forth turns one agent may have with another before the gate cuts it off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Stepper(
                    value: Binding(
                        get: { settings.a2aMaxChainDepth },
                        set: { settings.setA2AMaxChainDepth($0) }
                    ),
                    in: SettingsStore.a2aMaxChainDepthRange
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max chain depth: \(settings.a2aMaxChainDepth)")
                        Text("How deep a chain of agents-calling-agents can go before further nested calls are blocked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Agent-to-agent limits")
            } footer: {
                Text("Guardrails for when one agent delegates to another — the orchestrator fanning out to myApp agents, or a Slack room. Changes take effect on the next agent call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { settings.toolRoundsUnlimited },
                    set: { settings.setToolRoundsUnlimited($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No limit")
                        Text("On by default: a turn runs as many tool rounds as it needs. Turn this off to add a client-side breaker for turns you want cut short.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Stepper(
                    value: Binding(
                        get: { settings.maxToolRounds },
                        set: { settings.setMaxToolRounds($0) }
                    ),
                    in: SettingsStore.maxToolRoundsRange
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tool rounds per turn: \(settings.maxToolRounds)")
                        Text("How many tool round-trips one turn may take before the client stops it. Each on-device tool call (adding a component, editing a memory…) uses one. Raise it for long multi-step turns.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(settings.toolRoundsUnlimited)
            } header: {
                Text("Turn limits")
            } footer: {
                Text("A turn that hits this limit finishes the tool calls already in flight, then stops with a note in the chat. Applies on the next message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Limits")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
