import XCTest
@testable import MenfezCore

final class UpdateFeedTests: XCTestCase {
    func testEachArchitectureHasItsOwnHTTPSFeed() {
        let arm = UpdateFeed.url(arm64: true), intel = UpdateFeed.url(arm64: false)
        XCTAssertTrue(arm.hasPrefix("https://"))
        XCTAssertTrue(intel.hasPrefix("https://"))
        XCTAssertTrue(arm.hasSuffix("/appcast-arm64.xml"))
        XCTAssertTrue(intel.hasSuffix("/appcast-intel.xml"))
    }

    func testTheRunningSliceReadsItsOwnFeed() {
        #if arch(arm64)
        XCTAssertEqual(UpdateFeed.current, UpdateFeed.url(arm64: true))
        #else
        XCTAssertEqual(UpdateFeed.current, UpdateFeed.url(arm64: false))
        #endif
    }
}
