import XCTest
@testable import MenfezCore

final class OnboardingTests: XCTestCase {

    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        d = UserDefaults(suiteName: "OnboardingTests")
        d.removePersistentDomain(forName: "OnboardingTests")
    }

    override func tearDown() {
        d.removePersistentDomain(forName: "OnboardingTests")
        super.tearDown()
    }

    func testNewUserSeesItOnce() {
        XCTAssertTrue(Onboarding.shouldShow(d))
        Onboarding.markSeen(d)
        XCTAssertFalse(Onboarding.shouldShow(d))
    }

    func testUpgradingUserNeverSeesIt() {
        for key in Onboarding.earlierRunKeys {
            d.removePersistentDomain(forName: "OnboardingTests")
            d.set(key == "whatsNewSeen" ? "1.0.2" : "x", forKey: key)
            XCTAssertFalse(Onboarding.shouldShow(d), key)
        }
    }

    func testKeysMatchTheirOwners() {
        XCTAssertTrue(Onboarding.earlierRunKeys.contains(DPIEngine.portDefaultsKey))
    }
}
