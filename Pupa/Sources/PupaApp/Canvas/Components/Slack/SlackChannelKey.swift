import Foundation

/// Identifies one Slack channel across the whole app, for view `@State` that
/// outlives the component it belongs to — `CanvasView` builds component views
/// without `.id(component.id)`, so a `SlackView`'s state survives the canvas
/// swapping in a different Slack component.
///
/// All three parts are load-bearing. `MiniAppStore.nextSlackId` uniques channel
/// ids against one component's own channels, so the first channel of every
/// component is `"channel-1"`; component ids are uniqued per MiniApp, so the
/// first Slack component of every MiniApp is `"slack-1"`. Neither the channel id
/// nor the MiniApp id alone separates two workspaces.
///
/// Tracker's `TrackerBoardKey` is the same idea one level up, for state scoped
/// to a board rather than a channel.
struct SlackChannelKey: Hashable {
    let miniAppId: UUID
    let componentId: String
    let channelId: String
}
