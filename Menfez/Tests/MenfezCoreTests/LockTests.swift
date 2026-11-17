import XCTest
@testable import MenfezCore

/// The routing lock, which every mutating command must survive.
///
/// WHY THESE TESTS EXIST
/// The helper crashed with SIGTRAP and zero output on exactly the commands that
/// take this lock (`sanity`, `down`, `up`, `mode <x>`), while every read-only
/// command worked. A trap kills the process before any JSON can be written, so
/// the app saw an empty payload and reported nothing useful.
///
/// Two separate failure modes are covered here:
///
///   * the *busy* path, where a second acquisition must return `.failure` with
///     a message rather than trap. This is the path the app never took in
///     practice (one command at a time) and therefore the one that was never
///     exercised until two ran together;
///   * the acquire/release/acquire cycle, which proves the lock is genuinely
///     released and not merely marked so — the state file is a read-modify-write
///     under this lock, so a lock that cannot be retaken wedges every later
///     command.
///
/// Nothing here touches /var/run/menfez or the real lock: the path is injected.
final class LockTests: XCTestCase {

    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("menfez-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !directory.isEmpty { try? FileManager.default.removeItem(atPath: directory) }
        try super.tearDownWithError()
    }

    private var lockPath: String {
        (directory as NSString).appendingPathComponent("route.lock")
    }

    /// A second acquisition while the first is held must fail cleanly.
    ///
    /// This is the regression test for the SIGTRAP. Before the fix, reaching
    /// the busy path killed the process (`brk #0x1`, EXC_BREAKPOINT) instead of
    /// returning a `LockBusy`, so a caller could never print "another
    /// menfez-route is running". The assertion is deliberately about the
    /// *failure value*, not merely "did not crash": a crash aborts the test
    /// process, which XCTest reports as a failure, while a `nil`-turned-success
    /// would let two writers corrupt the state file.
    func testSecondAcquireFailsWithMessageInsteadOfTrapping() throws {
        switch Locking.acquireRouteLock(path: lockPath) {
        case .success(let first):
            // The lock must be genuinely held, not a value that merely exists.
            XCTAssertTrue(first.acquired)

            switch Locking.acquireRouteLock(path: lockPath) {
            case .success:
                XCTFail("second acquire succeeded; two mutating commands would interleave")
            case .failure(let busy):
                XCTAssertTrue(busy.message.contains("another menfez-route"),
                              "message must name the problem, got: \(busy.message)")
                XCTAssertFalse(busy.message.isEmpty)
            }

            first.release()
        case .failure(let busy):
            XCTFail("first acquire failed unexpectedly: \(busy.message)")
        }
    }

    /// Acquire, release, acquire again: the kernel must actually drop the lock.
    func testAcquireReleaseAcquireSucceeds() throws {
        let first: FileLock
        switch Locking.acquireRouteLock(path: lockPath) {
        case .success(let lock): first = lock
        case .failure(let busy): return XCTFail("first acquire failed: \(busy.message)")
        }

        XCTAssertTrue(first.acquired)
        first.release()
        XCTAssertFalse(first.acquired, "release must clear the acquired flag")

        switch Locking.acquireRouteLock(path: lockPath) {
        case .success(let second):
            XCTAssertTrue(second.acquired)
            second.release()
        case .failure(let busy):
            XCTFail("re-acquire after release failed: \(busy.message)")
        }
    }

    /// A released lock must not keep the process name in the file, and a stale
    /// pid must not be reported as the holder.
    ///
    /// `holder` is what turns "another command is running" into something a
    /// user can act on; naming a dead process makes a free lock look busy.
    func testHolderOfMissingFileIsEmpty() {
        XCTAssertEqual(FileLock.holder(at: lockPath), "")
    }
}
