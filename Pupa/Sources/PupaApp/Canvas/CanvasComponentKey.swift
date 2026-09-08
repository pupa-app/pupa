import Foundation

/// Identity of one rendered canvas component. **Every piece of per-component
/// view `@State` must be keyed on this** — nothing else identifies a component.
///
/// `CanvasView` renders one component into a single structural slot with no
/// `.id(...)`, so a component view's `@State` outlives the component it belongs
/// to and is reused when the canvas swaps another component of the same kind
/// into that slot. The state therefore has to carry its own scoping.
///
/// The component id alone will not do it: `MyAppStore.addComponent` uniques ids
/// against one MyApp's own components, so every MyApp's first tracker is
/// `"tracker-1"` and its first Slack component is `"slack-1"`. Four bugs have
/// come from keying on it — see `docs/adding-a-component.md`.
///
/// `nil` and `""` normalise to one key, matching the `componentId ?? ""` the
/// views used before this type existed.
struct CanvasComponentKey: Hashable {
    let myAppId: UUID
    let componentId: String

    init(myAppId: UUID, componentId: String?) {
        self.myAppId = myAppId
        self.componentId = componentId ?? ""
    }
}
