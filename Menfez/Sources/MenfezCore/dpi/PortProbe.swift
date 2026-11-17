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

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
