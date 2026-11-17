// NetworkChangeWatcher.swift — re-pin the tunnel endpoint after the network moves.
//
// K5: the endpoint host route is pinned to the physical gateway that existed at
// `up` time. After a Wi-Fi switch or a sleep/wake on another network that
// gateway is gone, the transport dies, and in "all" mode the /1 routes then
// black-hole all IPv4. Nothing used to notice. This watches the physical path
// and the wake notification and asks the helper to `repin`, debounced, off the
// main thread. `repin` itself is a no-op when nothing changed.

import Foundation
import Network

public final class NetworkChangeWatcher: @unchecked Sendable {
    /// Raw value of `NSWorkspace.didWakeNotification`; spelled out so this
    /// library does not link AppKit into the root helper.
    public static let wakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")

    private let queue = DispatchQueue(label: "menfez.network-watch")
    private let monitor = NWPathMonitor()
    private let debounce: TimeInterval
    private let isActive: @Sendable () -> Bool
    private let action: @Sendable () -> Void
    private let wakeCenter: NotificationCenter?
    private var wakeObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var lastSignature: String?

    /// `isActive` defaults to "the route state records a mode with a pin"; the
    /// state file is world-readable, so this costs no privileged call.
    public init(wakeCenter: NotificationCenter? = nil,
                debounce: TimeInterval = 2,
                isActive: @escaping @Sendable () -> Bool = {
                    let state = RouteStateStore.load()
                    return state.mode != Mode.off.rawValue && !state.hosts.isEmpty
                },
                action: @escaping @Sendable () -> Void) {
        self.wakeCenter = wakeCenter
        self.debounce = debounce
        self.isActive = isActive
        self.action = action
    }

    deinit {
        monitor.cancel()
        if let wakeObserver { wakeCenter?.removeObserver(wakeObserver) }
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(Self.signature(path))
        }
        monitor.start(queue: queue)
        wakeObserver = wakeCenter?.addObserver(forName: Self.wakeNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.schedule() }
        }
    }

    /// Physical interfaces and gateways; a utun is `.other` and is ignored so
    /// the tunnel's own changes do not trigger a re-pin.
    static func signature(_ path: NWPath) -> String {
        let names = path.availableInterfaces
            .filter { $0.type != .other && $0.type != .loopback }
            .map(\.name)
        return "\(path.status)|\(names.joined(separator: ","))|\(path.gateways.map { "\($0)" }.joined(separator: ","))"
    }

    /// Called on `queue`. The first path is the baseline, not a change.
    func pathChanged(_ signature: String) {
        defer { lastSignature = signature }
        guard let last = lastSignature, last != signature else { return }
        schedule()
    }

    /// Called on `queue`. A burst of changes collapses into one helper call.
    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive() else { return }
            self.action()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Test hook: run `body` on the watcher's queue.
    func onQueue(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }
}
