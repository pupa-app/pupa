import XCTest

/// Launch cost only. Behaviour lives in `ChatFlowUITests`; capture frames live
/// in `ScreenshotTests`.
final class PupaHostUITests: XCTestCase {

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
