// LoginItem.swift — "Launch at login", with a fallback for ad-hoc builds.
//
// The modern route is `SMAppService.mainApp`. An ad-hoc signed bundle can be
// refused there (register throws); then the app writes a plain per-user
// LaunchAgent instead. A registration waiting for the user's approval is kept
// as it is: the app sends the user to System Settings rather than adding a
// second mechanism. Turning it off removes whichever is present. Only a copy
// in /Applications or ~/Applications may be registered, so a login item
// never points at a download folder or a translocated copy.
//
// The service is a protocol so the tests drive a fake and a temp directory;
// nothing here touches the real ~/Library/LaunchAgents unless the app passes it.

import Foundation

public enum LoginServiceStatus: Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

/// The slice of `SMAppService` this needs.
public protocol LoginService {
    var status: LoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

public struct LoginItem {
    public enum Method: Equatable, Sendable { case service, launchAgent, needsApproval }

    public static let agentLabel = "com.menfez.app.loginitem"

    public let service: LoginService
    public let agentURL: URL
    /// What the LaunchAgent runs, e.g. `["/usr/bin/open", "-a", appPath]`.
    public let program: [String]

    public init(service: LoginService, agentURL: URL, program: [String]) {
        self.service = service
        self.agentURL = agentURL
        self.program = program
    }

    /// The per-user LaunchAgents path for `home`.
    public static func agentURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// Whether the app at `bundlePath` sits in /Applications or ~/Applications.
    public static func isInstalled(bundlePath: String, home: URL) -> Bool {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let roots = ["/Applications/", home.standardizedFileURL.path + "/Applications/"]
        return roots.contains { path.hasPrefix($0) }
    }

    /// On if either mechanism is in place, or the service waits for approval.
    public var isEnabled: Bool {
        [.enabled, .requiresApproval].contains(service.status)
            || FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Registered, but the user has not approved it in System Settings yet.
    public var needsApproval: Bool { service.status == .requiresApproval }

    /// Turn it on. Returns the mechanism that took.
    @discardableResult
    public func enable() throws -> Method {
        if (try? service.register()) != nil {
            switch service.status {
            case .enabled: return .service
            // The user's call: keep it and let the app open System Settings.
            case .requiresApproval: return .needsApproval
            default: break
            }
        }
        // Do not leave a half-registered entry beside the agent.
        if service.status != .notRegistered { try? service.unregister() }
        try writeAgent()
        return .launchAgent
    }

    /// Turn it off, whichever way it was turned on.
    public func disable() throws {
        if service.status != .notRegistered { try? service.unregister() }
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }

    /// The agent plist. Exposed so the test can check the shape launchd reads.
    public func agentPlist() -> [String: Any] {
        ["Label": Self.agentLabel, "ProgramArguments": program, "RunAtLoad": true]
    }

    private func writeAgent() throws {
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: agentPlist(),
                                                      format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }
}
