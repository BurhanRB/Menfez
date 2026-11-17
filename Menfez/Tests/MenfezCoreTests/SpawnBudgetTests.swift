import XCTest
@testable import MenfezCore

/// Counts what one UI refresh costs, before and after the read-path change.
///
/// WHY A SEPARATE FILE
/// `ReadPathTests` asserts the contract ("the fast path spawns nothing
/// privileged"). This file produces the numbers that justify the change, so the
/// next person can re-run it instead of trusting a paragraph in a doc.
///
/// HOW THE "BEFORE" NUMBER IS HONEST
/// It is not a formula. `ReportBuilder.build` is the exact function the helper
/// runs for `report --fast`, and `WireGuardProfiles.list(resolveLiveHost: true)`
/// is the exact function it runs for `profiles`, and `DNSManager().report()` is
/// `dns status`. Driving those three through a recording runner counts the same
/// `Shell.run` calls the root process made — same code, no privileleged spawn
/// needed to observe it. The only thing the recorder cannot observe is the
/// `sudo` and helper processes themselves, which are added as 2 per call.
final class SpawnBudgetTests: XCTestCase {

    /// The recorder from `ReadPathTests`, duplicated so this file can be read
    /// and run on its own.
    final class Counter: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(tool: String, args: [String])] = []
        var failEverything = false

        var calls: [(tool: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        var count: Int { calls.count }

        func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
            lock.lock(); _calls.append((tool, args)); lock.unlock()
            if failEverything {
                return CommandResult(status: 127, output: "\(tool): not found")
            }
            // Minimal plausible answers so the code takes its normal path
            // rather than its early-exit path.
            if tool == "wg" {
                if args == ["show", "interfaces"] {
                    return CommandResult(status: 0, output: "utun9\n")
                }
                return CommandResult(status: 0, output: "")
            }
            switch (tool, args.first) {
            case ("ifconfig", _):             return CommandResult(status: 0, output: "up")
            case ("route", _):
                if args.contains("default") {
                    return CommandResult(status: 0,
                                         output: "gateway: 192.168.1.1\ninterface: en0\n")
                }
                return CommandResult(status: 0, output: "destination: x\ninterface: utun9\n")
            case ("networksetup", _):
                if args.contains("-listnetworkserviceorder") {
                    return CommandResult(status: 0,
                                         output: "(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n")
                }
                return CommandResult(status: 0, output: "1.1.1.1\n")
            case ("ipconfig", _):             return CommandResult(status: 0, output: "192.168.1.2\n")
            case ("dig", _):                  return CommandResult(status: 0,
                                                                  output: ";; Query time: 7 msec\n")
            case ("curl", _):                 return CommandResult(status: 0, output: "203.0.113.7")
            default:                          return CommandResult(status: 0, output: "")
            }
        }

        var privileged: Int {
            calls.filter { call in
                call.tool == "sudo"
                    || (call.tool == "wg" && call.args.count >= 2
                        && call.args[0] == "show" && call.args[1] != "interfaces")
            }.count
        }
    }

    private func statePath(withPrefixes n: Int) -> String {
        let dir = NSTemporaryDirectory() + "menfez-budget-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/route-state.json"
        let prefixes = Array(RouteManager.discordRanges.prefix(n))
        XCTAssertTrue(RouteStateStore.save(
            RouteState(mode: "discord", iface: "utun9",
                       routes: prefixes, hosts: ["203.0.113.69"],
                       gateway: "192.168.1.1", profile: "p", generation: 1),
            path: path))
        return path
    }

    /// The number for the doc: one old tick versus one new tick.
    ///
    /// Prints a table, so `swift test --filter SpawnBudgetTests` is the
    /// measurement command. Nothing here asserts a wall-clock time; those are
    /// in docs/READ-PATH.md and come from `/usr/bin/time` against the real
    /// helper, because a CI machine's speed is not this machine's speed.
    func testRefreshBudgetBeforeAndAfter() {
        let path = statePath(withPrefixes: 2)

        // BEFORE: report --fast + profiles + dns status, as the helper ran them.
        let before = Counter()
        _ = ReportBuilder().build(full: false, statePath: path, using: before)
        let afterReport = before.count
        _ = WireGuardProfiles.list(liveHost: nil, resolveLiveHost: true, using: before)
        let afterProfiles = before.count - afterReport
        _ = DNSManager().report(using: before)
        let afterDNS = before.count - afterReport - afterProfiles
        let beforeChildren = before.count

        // AFTER: one local report.
        let after = Counter()
        _ = ReportBuilder().buildLocal(statePath: path, using: after)
        let afterTick = after.count

        print("""

        ┌───────────────────────────────────────────────────────────────────┐
        │ one UI refresh, process spawns                                    │
        ├───────────────────────────────────────────────────────────────────┤
        │ BEFORE  report --fast children          \(pad(afterReport))                     │
        │ BEFORE  profiles children               \(pad(afterProfiles))                     │
        │ BEFORE  dns status children             \(pad(afterDNS))                     │
        │ BEFORE  children per tick               \(pad(beforeChildren))                     │
        │ BEFORE  sudo + helper per call          \(pad(6))                     │
        │ BEFORE  privileged spawns per tick      \(pad(before.privileged + 3))                     │
        ├───────────────────────────────────────────────────────────────────┤
        │ AFTER   children per fast tick          \(pad(afterTick))                     │
        │ AFTER   privileged spawns per tick      \(pad(after.privileged))                     │
        └───────────────────────────────────────────────────────────────────┘

        """)

        XCTAssertEqual(after.privileged, 0,
                       "the fast path must not spawn anything privileged")
        XCTAssertGreaterThan(beforeChildren, 5,
                             "the old tick really did shell out; if this drops the "
                             + "comparison below is meaningless")
        XCTAssertGreaterThan(before.privileged, 0)
        XCTAssertLessThan(afterTick, beforeChildren,
                          "the new tick must be cheaper than the old one")
    }

    private func pad(_ n: Int) -> String {
        let text = String(n)
        return text + String(repeating: " ", count: max(0, 8 - text.count))
    }

    /// Wall clock for one real fast tick, and for the old privileged tick.
    ///
    /// This one uses the *real* runner, so the numbers are what this machine
    /// actually does. It starts only read-only commands: `wg show interfaces`,
    /// `route -n get`, `networksetup -getdnsservers`, `ifconfig`, `ipconfig`.
    /// Nothing here mutates the route table, the resolver or the tunnel.
    ///
    /// The old tick cannot be timed here without `sudo`, so its number is left
    /// to a manual measurement run as root.
    func testRealFastTickWallClock() throws {
        guard ProcessInfo.processInfo.environment["MENFEZ_SKIP_LIVE"] == nil else {
            throw XCTSkip("MENFEZ_SKIP_LIVE is set")
        }

        let path = statePath(withPrefixes: 2)
        let builder = ReportBuilder()

        // Warm up once: the first call pays for the page cache on `route` and
        // `networksetup`, and a UI tick never does that after launch.
        _ = builder.buildLocal(statePath: path)

        let samples = 5
        let started = Date()
        for _ in 0..<samples {
            _ = builder.buildLocal(statePath: path)
        }
        let each = Date().timeIntervalSince(started) / Double(samples)

        print("""

        one real fast tick (report, no root): \(String(format: "%.1f", each * 100)) ms

        """)

        // A fast tick has to stay well inside its own 2 s period; if it ever
        // grows past that the timer would queue up behind itself.
        XCTAssertLessThan(each, 1.0, "a local tick must not approach its own period")
    }

    ///
    /// This is the number the deliverable quotes. The tick rates are hard-coded
    /// here on purpose: if someone changes `activeTick` in the app, this test
    /// keeps reporting the historical comparison, and the doc stays a record of
    /// what the change did rather than of what the code does today.
    func testThirtySecondsOfIdle() {
        let path = statePath(withPrefixes: 2)

        let before = Counter()
        _ = ReportBuilder().build(full: false, statePath: path, using: before)
        _ = WireGuardProfiles.list(liveHost: nil, resolveLiveHost: true, using: before)
        _ = DNSManager().report(using: before)
        // Each of the three calls is `sudo <helper>`, i.e. two extra processes.
        let beforePerTick = before.count + 6

        let after = Counter()
        _ = ReportBuilder().buildLocal(statePath: path, using: after)
        let afterPerTick = after.count

        let oldTicks = 30 / 5            // 6
        let newTicks = 30 / 2            // 15, frontmost
        let factsCalls = 30 / 25         // 1
        let factsSpawns = 6              // sudo + helper + 4 wg reads

        let beforeTotal = oldTicks * beforePerTick
        let afterTotal = newTicks * afterPerTick + factsCalls * factsSpawns

        print("""

        30 seconds of idle, window frontmost:
          before: \(oldTicks) ticks x \(beforePerTick) = \(beforeTotal) processes, \
        \(oldTicks * 3) root
          after:  \(newTicks) ticks x \(afterPerTick) + \(factsCalls) facts call \
        = \(afterTotal) processes, \(factsCalls) root

        30 seconds of idle, window in the background:
          before: \(oldTicks) ticks x \(beforePerTick) = \(beforeTotal) processes, \
        \(oldTicks * 3) root
          after:  2 ticks x \(afterPerTick) = \(2 * afterPerTick) processes, 0 root

        """)

        XCTAssertLessThan(afterTotal, beforeTotal)
    }
}
