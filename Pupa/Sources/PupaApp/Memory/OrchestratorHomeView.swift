import SwiftUI

/// Detail-pane content shown when the sidebar's "Orchestrator" row is
/// selected. The chat overlay (memory-mode session) floats over it; this
/// view's job is just to give that chat a meaningful backdrop and tell the
/// user what's possible from here.
public struct OrchestratorHomeView: View {
    @Bindable var store: MyAppStore
    /// Tapping the Agent panel pushes the orchestrator's detail page onto
    /// the detail stack. Wired by `AppView` the same way per-MyApp Agent
    /// panels are wired in `MyAppHomeView`.
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        onNavigate: @escaping (SidebarSelection) -> Void = { _ in }
    ) {
        self.store = store
        self.onNavigate = onNavigate
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                description
                agentPanel
                myAppsPanel
                examples
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
    }

    /// Mirrors the per-MyApp Agents panel: one-row preview pushing the
    /// orchestrator's `AgentDetailView` so the user can pick its model,
    /// edit its AGENTS.md, and see its tool surface.
    private var agentPanel: some View {
        Button {
            onNavigate(.orchestratorAgentDetail)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("Model, permissions, prompt, tool surface")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Orchestrator")
                .font(.title)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat across all your myapps.")
                .font(.headline)
            Text("Use this chat to plan, delegate work to a myapp's agent, or create a new myapp — without opening any single myapp's canvas. Each delegation runs as a fresh sub-agent against the target myapp; you can fan out to several myapps at once and the orchestrator collects the replies.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var myAppsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Myapps you can drive")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(store.myApps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.myApps.isEmpty {
                Text("No myapps yet — ask the orchestrator to create one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.myApps) { myApp in
                        HStack(spacing: 10) {
                            Image(systemName: myApp.iconSystemName)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            Text(myApp.name)
                                .font(.callout)
                            Spacer()
                            Text(myApp.typeId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.12))
                                )
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.subheadline)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 4) {
                examplePrompt("Create a tracker myapp called \"Garden\".")
                examplePrompt("Ask the Books myapp to suggest 3 sci-fi novels with summer themes.")
                examplePrompt("Add 5 succulents to the Garden tracker and 3 cookbooks to Books.")
            }
        }
    }

    private func examplePrompt(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}
