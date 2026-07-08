import SwiftUI

/// Editable model selector rendered as a `Menu` grouped by provider. The
/// options come from `ModelCatalogStore.models` (fetched from the backend)
/// plus a "Backend default" sentinel entry that clears the override.
///
/// Two styles:
/// - full (`compact == false`): a labelled chip + provider subtitle + refresh
///   state + a "Reload models" menu item. Used in the agent details page.
/// - compact (`compact == true`): model name + chevron only, sized to sit
///   beside the chat header's thread dropdown. No provider subtitle, no reload
///   item — the catalog is already refreshed app-wide and from the agent panel.
struct ModelPickerRow: View {
    let selectedId: String
    let options: [KnownLLMModel]
    var onSelect: (String) -> Void
    /// Re-fetch `GET /models` from the active backend. Exposed as a menu item
    /// (full style only) so a stale or failed catalog can be reloaded without
    /// relaunching.
    var onReload: () -> Void = {}
    var isRefreshing: Bool = false
    var loadFailed: Bool = false
    /// Render the minimal header variant instead of the full agent-panel row.
    var compact: Bool = false

    /// The model the picker rests on. Prefers the explicit selection, else the
    /// catalog's first entry (the backend default). When the catalog is empty
    /// (backend unreachable) there is no concrete model — the label falls back
    /// to a status string rather than inventing a hardcoded default.
    private var resolvedModel: KnownLLMModel? {
        options.first(where: { $0.id == selectedId }) ?? options.first
    }

    private var currentLabel: String {
        if let model = resolvedModel { return model.label }
        return loadFailed ? "Backend unreachable" : "Backend default"
    }

    private var currentSecondary: String? {
        guard let model = resolvedModel else { return nil }
        return KnownLLMModelCatalog.providerDisplayName(model.provider)
    }

    private var grouped: [(provider: String, items: [KnownLLMModel])] {
        let order = options.map(\.provider).reduce(into: [String]()) { acc, p in
            if !acc.contains(p) { acc.append(p) }
        }
        return order.map { provider in
            (provider, options.filter { $0.provider == provider })
        }
    }

    var body: some View {
        Menu {
            if options.isEmpty {
                // No models: never fabricate a fallback — say why the list is empty.
                Text(loadFailed ? "Backend unreachable — models unavailable"
                                : "No models available")
            }
            ForEach(grouped, id: \.provider) { group in
                Section(KnownLLMModelCatalog.providerDisplayName(group.provider)) {
                    ForEach(group.items) { model in
                        Button {
                            onSelect(model.id)
                        } label: {
                            if model.id == selectedId {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                }
            }
            if !compact {
                Divider()
                Button(action: onReload) {
                    Label(isRefreshing ? "Reloading…" : "Reload models",
                          systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        } label: {
            if compact { compactLabel } else { fullLabel }
        }
        .buttonStyle(.plain)
    }

    /// Minimal name + chevron, styled to match the thread dropdown beside it.
    private var compactLabel: some View {
        HStack(spacing: 3) {
            Text(currentLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .contentShape(Rectangle())
    }

    private var fullLabel: some View {
        HStack(spacing: 6) {
            Text(currentLabel)
                .font(.callout)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                )
            if let secondary = currentSecondary {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else if loadFailed {
                // Couldn't reach the backend — the list may be the static
                // fallback rather than the backend's real catalog.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
