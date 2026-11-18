// PortProbe.swift — is something accepting TCP on this loopback port?
//
// WHY THE ENGINE NEEDS THIS
// `NWListener.cancel()` is asynchronous: it returns while the socket is still
// bound. Without a way to observe "the port is free now", `stop()` could report
// success and leave the port unusable for the next `start()`, which is exactly
// the "turn it off and on again does nothing" failure.
//
// A connect is used rather than a bind because a bind can succeed against a
// socket in TIME_WAIT, which is not the condition that breaks a restart.

import Foundation

public enum PortProbe {

    /// True when a TCP connection to 127.0.0.1:`port` is accepted.
    ///
    /// The connection is closed immediately; the proxy will see an empty read
    /// and drop it, which is what it does for any client that sends nothing.
    public static func isListening(port: Int) -> Bool {
        guard port > 0, port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        // Non-blocking with a short wait: when a packet filter drops the
        // loopback reset (seen with a kill switch on, 1.0.8) a blocking
        // connect to a closed port hangs for over a minute.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeoutMs)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    /// A loopback answer takes microseconds. Longer means nobody answered.
    static let timeoutMs = 250
}
