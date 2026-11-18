// Snapshots.swift — debug-only PNG renders of the main window for review.
//
//   MENFEZ_SNAPSHOT_DIR=/some/dir swift run Menfez
//
// writes dark, light and dark-tunnel PNGs of the main
// view with fixed fake state, then exits before the app starts. Nothing here
// is compiled into a release build.

#if DEBUG
import SwiftUI
import AppKit
import MenfezCore

/// A tunnel that says it is up, for the tunnel-mode shot only.
private struct CarryingTunnel: TunnelControl {
    func isTunnelUp() -> Bool { true }
    func start(mode: Mode) -> TunnelOutcome { TunnelOutcome(ok: true, message: "snapshot") }
    func stop() -> TunnelOutcome { TunnelOutcome(ok: true, message: "snapshot") }
}

/// A proxy that says it is listening, for the DPI-mode shots only.
@MainActor
private final class RunningProxy: ProxyControl {
    var status = DPIStatus(running: true, port: 64799, connections: 3, reframed: 12, passthrough: 2)
    func enable(tunnelBusy: Bool?) async -> DPIModeResult { DPIModeResult(ok: true, message: "snapshot", status: status) }
    func disable() async -> DPIModeResult { DPIModeResult(ok: true, message: "snapshot", status: status) }
    func shutdown() {}
}

/// AppKit-backed toggles do not draw in `ImageRenderer`; this stands in for
/// the menu's checkmark in the snapshot only.
private struct MenuCheck: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Text(configuration.isOn ? "✓" : " ").frame(width: 12)
            configuration.label
        }
    }
}

@MainActor
enum Snapshots {
    static func renderIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["MENFEZ_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // One fixed state for every shot: direct mode, tunnel available.
        let m = Model()
        m.lang = .tr
        m.capabilities = Capabilities(tunnelAvailable: true)
        m.report = Report(
            dns: ["1.1.1.1"],
            gateway: "192.168.1.1",
            egressIP: "88.241.102.37",
            geo: Geo(country: "TR", city: "İstanbul", org: "Turk Telekomunikasyon A.S.",
                     ispShort: "Türk Telekom"),
            discord: DiscordProbe(code: 0))
        m.status = ""

        // The window is the content's own size, so each shot is too.
        render(m, .dark, to: "\(dir)/dark.png")
        render(m, .light, to: "\(dir)/light.png")
        m.lang = .en
        render(m, .light, to: "\(dir)/light-en.png")
        m.lang = .tr
        render(m, .light, to: "\(dir)/direct.png")

        // The three panels, Turkish, light: help, about, and the IP popup with
        // the helper's English rows fed in as they arrive from the backend.
        renderView(HelpSheet(lang: .tr, helperPath: "/Applications/Menfez.app/Contents/MacOS/menfez-route",
                             onInstall: {}, showSetup: true),
                   .light, to: "\(dir)/help.png")
        renderView(HelpSheet(lang: .tr, helperPath: "/Applications/Menfez.app/Contents/MacOS/menfez-route",
                             installRunning: true, installMessage: m.l.t("tunnel_install_running"),
                             onInstall: {}, showSetup: true),
                   .light, to: "\(dir)/help-running.png")

        // The first-run guide, each page, on a machine without the helper.
        for page in 0..<3 {
            renderView(OnboardingSheet(lang: .tr, showTunnelSetup: true, page: page),
                       .light, to: "\(dir)/onboarding-\(page + 1).png")
        }

        // A finished site test: blocked directly, opens with DPI.
        // A window, not `ImageRenderer`: the text field is AppKit and would not draw.
        renderWindow(SiteTestSheet(lang: .tr, input: "ornek.com",
                                   report: SiteTest.Report(host: "ornek.com",
                                                           results: [.direct: .fails, .dpi: .opens],
                                                           summary: .opensWithDPI)),
                     title: "Menfez", .light, to: "\(dir)/sitetest.png")

        // The tunnel-setup row on a machine without the helper: idle, running,
        // failed, then the Settings window after a successful setup.
        m.installerHelper = "/Applications/Menfez.app/Contents/MacOS/menfez-route"
        m.capabilities = .dpiOnly(reason: TunnelSetup.notPermittedReason)
        render(m, .light, to: "\(dir)/tunnel-setup.png")
        m.tunnelInstall = .running(.install)
        render(m, .light, to: "\(dir)/tunnel-setup-running.png")
        m.tunnelInstall = .failed(.install, "WireGuard tools not found. Install them first: "
                                  + "brew install wireguard-tools wireguard-go bash")
        render(m, .light, to: "\(dir)/tunnel-setup-failed.png")
        renderWindow(SettingsView(m: m), title: "Menfez", .light, to: "\(dir)/settings-setup.png")
        m.capabilities = Capabilities(tunnelAvailable: true)
        m.tunnelInstall = .succeeded(.install)
        renderWindow(SettingsView(m: m), title: "Menfez", .light, to: "\(dir)/settings-remove.png")
        m.tunnelInstall = .idle
        renderView(AboutSheet(lang: .tr) {}, .light, to: "\(dir)/info.png")
        // A made-up older release, here only, to show the collapsed row.
        let older = ChangelogEntry(version: "0.9.9", date: "2026-10-01",
                                   tr: ["Örnek eski sürüm."], en: ["Sample older release."])
        renderView(WhatsNewSheet(lang: .tr, entries: Changelog.entries + [older],
                                 current: Changelog.entries.first?.version ?? "") {},
                   .light, to: "\(dir)/whatsnew.png")
        let ipRows = [("IP", "88.241.102.37"), ("Reverse DNS", "88.241.102.37.dynamic.ttnet.com.tr"),
                      ("City", "Istanbul"), ("Region", "Istanbul"), ("Country", "TR"),
                      ("Postal", "34000"), ("Timezone", "Europe/Istanbul"),
                      ("Coordinates", "41.0138,28.9497"), ("Network", "AS9121 Turk Telekom"),
                      ("Provider", "Türk Telekom"), ("Routing", "en0 via 192.168.1.1")]
            .map { DetailItem(label: $0.0, value: $0.1) }
        renderView(DetailView(sheet: DetailSheet(title: m.l.t("det_ip"), what: "ip",
                                                 value: nil, backend: m.backend),
                              lang: .tr, onClose: {}, preview: ipRows),
                   .light, to: "\(dir)/ipdetail.png")

        // DPI mode after a probe that found no blocking: the longest verdict,
        // which must wrap inside the DPI card and not repeat in the footer.
        let direct = m.coordinator
        m.coordinator = ModeCoordinator(dpi: RunningProxy(), tunnel: NoTunnel())
        m.coordinator.adoptExistingState(canManageTunnel: false)
        m.dpi = DPIStatus(running: true, port: 64799, connections: 3, reframed: 12, passthrough: 2)
        m.probe = DPIProbeOutcome(host: "discord.com",
                                  direct: .init(exit: 0, ms: 120), proxied: .init(exit: 0, ms: 140))
        render(m, .light, to: "\(dir)/dpi-verdict.png")
        m.probe = nil
        render(m, .light, to: "\(dir)/dpi.png")
        m.probe = DPIProbeOutcome(host: "discord.com",
                                  direct: .init(exit: 0, ms: 120), proxied: .init(exit: 0, ms: 140))
        m.lang = .en
        render(m, .dark, to: "\(dir)/dpi-verdict-en.png")
        m.lang = .tr
        m.probe = nil
        m.coordinator = direct

        // The DNS sheet, with every provider measured.
        m.dns = DNSReport(service: "Wi-Fi", current: ["1.1.1.1", "1.0.0.1"], presets: DNSManager.presets.map {
            var p = $0
            p.ms = p.v4.isEmpty ? nil : [11, 24, 19, 31, 42, 57][min(5, DNSManager.presets.firstIndex(of: $0) ?? 0)]
            p.ok = true
            p.active = p.id == "cloudflare"
            return p
        })
        renderView(ContentView(m: m).dnsSheet, .light, to: "\(dir)/dns.png")

        // Tunnel mode with a server chosen, so the pickers show.
        m.coordinator = ModeCoordinator(tunnel: CarryingTunnel())
        m.coordinator.adoptExistingState(canManageTunnel: true)
        m.tunnelCarriesTraffic = true
        m.profiles = [Profile(name: "nl-ams-01", file: "nl-ams-01.conf",
                              endpoint: "185.65.134.10:51820", host: "185.65.134.10", country: "NL",
                              display: "Hollanda · Amsterdam", active: true)]
        // Fake ipinfo answer for the server, so no lookup runs.
        m.serverAddr["185.65.134.10"] = "185.65.134.10"
        m.serverGeos["185.65.134.10"] = Geo(country: "NL", city: "Amsterdam",
                                            org: "AS39351 31173 Services AB", ispShort: "31173 Services")
        m.report?.tunnel = "utun4"
        m.report?.mode = "discord"
        m.report?.health = Health(ok: true, code: .ok, ageS: 12)
        m.report?.handshakeAgeS = 12
        m.report?.routes = [RouteInfo(cidr: "162.159.128.0/17", present: true),
                            RouteInfo(cidr: "66.22.192.0/18", present: true)]
        m.report?.transfer = Transfer(rx: 48_300_000, tx: 3_100_000)
        m.report?.discord = DiscordProbe(code: 200, ms: 84)
        m.tunnelScope = .discord
        render(m, .dark, to: "\(dir)/dark-tunnel.png")
        render(m, .light, to: "\(dir)/tunnel.png")

        // The scope control, both choices side by side. Whole internet's card
        // shows the egress lookup, which now leaves through the server.
        let saved = m.report
        render(m, .light, to: "\(dir)/tunnel-scope-discord.png")
        m.tunnelScope = .all
        m.report?.mode = "all"
        m.report?.routes = ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]
            .map { RouteInfo(cidr: $0, present: true) }
        m.report?.egressIP = "185.65.134.77"
        m.report?.geo = Geo(country: "NL", city: "Amsterdam",
                            org: "AS39351 31173 Services AB", ispShort: "31173 Services")
        m.report?.dns = ["10.64.0.1"]
        render(m, .light, to: "\(dir)/tunnel-scope-all.png")
        sideBySide("\(dir)/tunnel-scope-discord.png", "\(dir)/tunnel-scope-all.png",
                   to: "\(dir)/tunnel-scope.png")
        m.report = saved
        m.tunnelScope = .discord
        let servers = m.profiles
        m.profiles += [Profile(name: "bg-sof", file: "bg-sof.conf", endpoint: "94.156.1.20:51820",
                               country: "BG", display: "Bulgaristan")]
        renderView(ContentView(m: m).serverSheet, .light, to: "\(dir)/servers.png")
        m.profiles = servers

        // Menu-bar pieces. A real NSMenu cannot be rendered offscreen, so the
        // menu's items are laid out as plain controls: same content, same order.
        renderView(VStack(alignment: .leading, spacing: 6) { MenuBarContent(m: m) }
                    .buttonStyle(.plain).toggleStyle(MenuCheck())
                    .padding(12).frame(width: 300).background(Palette.bg),
                   .dark, to: "\(dir)/menubar-menu-tunnel.png")
        m.profiles = []
        renderView(VStack(alignment: .leading, spacing: 6) { MenuBarContent(m: m) }
                    .buttonStyle(.plain).toggleStyle(MenuCheck())
                    .padding(12).frame(width: 300).background(Palette.bg),
                   .light, to: "\(dir)/menubar-menu-noprofiles.png")
        renderView(HStack(spacing: 14) {
                        ForEach(MenuBarModes.order, id: \.self) { MenuBarIcon(mode: $0) }
                    }.padding(10).background(Palette.bg),
                   .light, to: "\(dir)/menubar-icons.png")
        renderWindow(SettingsView(m: m), title: "Menfez", .dark, to: "\(dir)/settings.png")
        // Settings with the notification switches, Turkish, light.
        renderWindow(SettingsView(m: m), title: "Menfez", .light, to: "\(dir)/settings-notifications.png")

        exit(0)
    }

    /// Two shots in one PNG, left then right, tops aligned.
    private static func sideBySide(_ left: String, _ right: String, to path: String) {
        func load(_ p: String) -> CGImage? {
            NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let gap = 48
        guard let l = load(left), let r = load(right),
              let ctx = CGContext(data: nil, width: l.width + gap + r.width, height: max(l.height, r.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            FileHandle.standardError.write("snapshot failed: \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        ctx.draw(l, in: CGRect(x: 0, y: ctx.height - l.height, width: l.width, height: l.height))
        ctx.draw(r, in: CGRect(x: l.width + gap, y: ctx.height - r.height, width: r.width, height: r.height))
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print(path, image.width / 2, "x", image.height / 2, "pt")
    }

    private static func render(_ m: Model, _ scheme: ColorScheme, to path: String) {
        renderView(ContentView(m: m), scheme, to: path)
    }

    /// The Settings scene as macOS shows it: a real titled window, title bar
    /// included, drawn offscreen at its fitting size.
    private static func renderWindow<V: View>(_ content: V, title: String,
                                              _ scheme: ColorScheme, to path: String) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.title = title
        let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        guard let frame = host.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            FileHandle.standardError.write("snapshot failed: \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        frame.layoutSubtreeIfNeeded()
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path, Int(frame.bounds.width), "x", Int(frame.bounds.height), "pt")
    }

    private static func renderView<V: View>(_ content: V, _ scheme: ColorScheme, to path: String) {
        let view = content
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        // Dynamic NSColors resolve against the current drawing appearance.
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image,
              let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot failed: \(path)\n".data(using: .utf8)!)
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print(path, image.width / 2, "x", image.height / 2, "pt")
    }
}
#endif
