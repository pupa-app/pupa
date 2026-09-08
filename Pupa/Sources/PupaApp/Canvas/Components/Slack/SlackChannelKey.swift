import Foundation

/// Identity of one Slack channel, app-wide. `SlackView`'s per-channel `@State`
/// keys on this.
///
/// Composed from `CanvasComponentKey` because all three parts are load-bearing:
/// `MyAppStore.nextSlackId` uniques channel ids against one component's own
/// channels, so the first channel of every Slack component is `"channel-1"`.
/// The component half carries the rest — see `CanvasComponentKey`.
struct SlackChannelKey: Hashable {
    let component: CanvasComponentKey
    let channelId: String

    init(component: CanvasComponentKey, channelId: String) {
        self.component = component
        self.channelId = channelId
    }

    init(myAppId: UUID, componentId: String?, channelId: String) {
        self.init(
            component: CanvasComponentKey(myAppId: myAppId, componentId: componentId),
            channelId: channelId
        )
    }
}
