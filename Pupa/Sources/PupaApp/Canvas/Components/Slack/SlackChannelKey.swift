import Foundation

/// Identifies one Slack channel across the whole app, for view `@State` that
/// outlives the component it belongs to — `CanvasView` builds component views
/// without `.id(component.id)`, so a `SlackView`'s state survives the canvas
/// swapping in a different Slack component.
///
/// All three parts are load-bearing. `MyAppStore.nextSlackId` uniques channel
/// ids against one component's own channels, so the first channel of every
/// component is `"channel-1"`; component ids are uniqued per MyApp, so the
/// first Slack component of every MyApp is `"slack-1"`. Neither the channel id
/// nor the MyApp id alone separates two workspaces.
///
/// Tracker's `TrackerBoardKey` is the same idea one level up, for state scoped
/// to a board rather than a channel.
struct SlackChannelKey: Hashable {
    let myAppId: UUID
    let componentId: String
    let channelId: String
}
