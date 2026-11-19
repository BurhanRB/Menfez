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

final class UpdateBannerTests: XCTestCase {
    func testHiddenWithoutAVersion() {
        XCTAssertEqual(UpdateBanner(version: nil, readyToInstall: false, installing: false), .hidden)
        XCTAssertEqual(UpdateBanner(version: nil, readyToInstall: true, installing: false), .hidden)
    }

    func testReadyInstallsNowOtherwiseOpensSparkle() {
        XCTAssertEqual(UpdateBanner(version: "1.0.12", readyToInstall: true, installing: false), .installNow)
        XCTAssertEqual(UpdateBanner(version: "1.0.12", readyToInstall: false, installing: false), .openUpdater)
    }

    func testHiddenOnceTheInstallStarts() {
        XCTAssertEqual(UpdateBanner(version: "1.0.12", readyToInstall: true, installing: true), .hidden)
    }
}
