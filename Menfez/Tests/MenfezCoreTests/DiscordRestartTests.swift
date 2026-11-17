import XCTest
@testable import MenfezCore

final class DiscordRestartTests: XCTestCase {
    private let ps = """
      101 /sbin/launchd
      202 /Applications/Discord.app/Contents/MacOS/Discord --proxy-server=http://127.0.0.1:64799
      203 /Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper --type=gpu --proxy-server=http://127.0.0.1:64799
    """

    func testOffersOnlyWhenLeavingDPIWithOurProxy() {
        XCTAssertEqual(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .tunnel, port: 64799), 202)
        XCTAssertEqual(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .direct, port: 64799), 202)
        XCTAssertEqual(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .direct, port: nil), 202)
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: ps, from: .tunnel, to: .direct, port: 64799))
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .dpi, port: 64799))
    }

    func testNoOfferForOtherPortsPlainDiscordOrHelpersOnly() {
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .tunnel, port: 6479))
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: ps, from: .dpi, to: .tunnel, port: 1234))
        let plain = "  202 /Applications/Discord.app/Contents/MacOS/Discord\n"
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: plain, from: .dpi, to: .tunnel, port: nil))
        let helperOnly = ps.split(separator: "\n").filter { !$0.contains(" 202 ") }.joined(separator: "\n")
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: helperOnly, from: .dpi, to: .tunnel, port: 64799))
        XCTAssertNil(DiscordLauncher.restartCandidate(psOutput: "", from: .dpi, to: .tunnel, port: 64799))
    }
}
