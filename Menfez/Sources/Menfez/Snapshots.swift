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
        StatusDot.animates = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // One fixed state for every shot: direct mode, tunnel available.
        let m = Model()
        m.browserProxySyncs = false   // never run the helper from a snapshot
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
        let helperAt = "/Applications/Menfez.app/Contents/MacOS/menfez-route"
        renderView(HelpSheet(lang: .tr, helperPath: helperAt, onInstall: {}, showSetup: true),
                   .dark, to: "\(dir)/help-dark.png")
        renderView(HelpSheet(lang: .en, helperPath: helperAt, onInstall: {}, showSetup: true),
                   .light, to: "\(dir)/help-en.png")
        // A long failure message beside the install and copy buttons.
        renderView(HelpSheet(lang: .tr, helperPath: helperAt,
                             installMessage: m.l.t("tunnel_install_need_wg"),
                             onInstall: {}, showSetup: true),
                   .light, to: "\(dir)/help-failed.png")

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
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(dir)/settings-setup.png")
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .dark, to: "\(dir)/settings-setup-dark.png")
        m.lang = .en
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Settings", .light, to: "\(dir)/settings-setup-en.png")
        m.lang = .tr
        m.capabilities = Capabilities(tunnelAvailable: true)
        m.tunnelInstall = .succeeded(.install)
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(dir)/settings-remove.png")
        m.tunnelInstall = .idle
        renderView(AboutSheet(lang: .tr) {}, .light, to: "\(dir)/info.png")
        renderView(AboutSheet(lang: .en) {}, .light, to: "\(dir)/about-licenses.png")
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
        let discordRows = Details.discordRows(probe: DiscordProbe(code: 200, ms: 52), names: nil)
        for (lang, scheme, name) in [(Lang.tr, ColorScheme.dark, "dark"), (.tr, .light, "light"), (.en, .light, "en")] {
            renderView(DetailView(sheet: DetailSheet(title: "Discord", what: "discord",
                                                     value: nil, backend: m.backend),
                                  lang: lang, onClose: {}, preview: discordRows),
                       scheme, to: "\(dir)/discorddetail-\(name).png")
        }

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

        // Find a setting (1.0.8): offered after "DPI isn't enough", then
        // progress, then each outcome.
        let f8 = "\(dir)/f8"
        try? FileManager.default.createDirectory(atPath: f8, withIntermediateDirectories: true)
        m.probe = DPIProbeOutcome(host: "discord.com",
                                  direct: .init(exit: 35, error: "TLS handshake failed"),
                                  proxied: .init(exit: 35, error: "TLS handshake failed"))
        render(m, .light, to: "\(f8)/tune-offer.png")
        m.tuning = .trying(3, 4)
        render(m, .dark, to: "\(f8)/tune-trying-dark.png")
        m.tuning = .done(.found(5))
        render(m, .light, to: "\(f8)/tune-found.png")
        m.tuning = .done(.noneWorked)
        render(m, .dark, to: "\(f8)/tune-none-dark.png")
        m.lang = .en
        m.tuning = .done(.found(5))
        render(m, .light, to: "\(f8)/tune-found-en.png")
        m.lang = .tr
        m.tuning = nil
        m.probe = nil

        // DPI in the browser (1.0.8): the toggle on with a list, the list
        // itself, then the dimmed toggle on an older helper.
        let f6 = "\(dir)/f6"
        try? FileManager.default.createDirectory(atPath: f6, withIntermediateDirectories: true)
        let savedBrowser = (m.browserProxyWanted, m.browserSites, m.helperVersion)
        m.helperVersion = HelperVersion.current
        m.browserProxyWanted = true
        m.browserSites = ["x.com", "reddit.com", "archive.org"]
        renderWindow(ContentView(m: m), title: "Menfez", .dark, to: "\(f6)/browser-on-dark.png")
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(f6)/browser-on.png")
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .dark, to: "\(f6)/browser-sites-dark.png")
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .light, to: "\(f6)/browser-sites.png")
        // 1.0.8 polish: the DPI group card, light, dark and English.
        let polish = "\(dir)/polish"
        try? FileManager.default.createDirectory(atPath: polish, withIntermediateDirectories: true)
        m.discordState = .withoutDPI
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(polish)/dpi-light.png")
        m.discordState = .viaDPI
        renderWindow(ContentView(m: m), title: "Menfez", .dark, to: "\(polish)/dpi-dark.png")
        m.lang = .en
        m.discordState = .closed
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(polish)/dpi-en.png")
        m.discordState = .closed
        m.lang = .tr
        let savedSites = m.browserSites
        m.browserSites += ["ornek.org"]
        m.browserSiteChecks = [
            "x.com": .init(outcome: "opens", at: Date().addingTimeInterval(-300)),
            "reddit.com": .init(outcome: "fails", at: Date().addingTimeInterval(-300)),
            "archive.org": .init(outcome: nil, at: Date()),
        ]
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .light, to: "\(polish)/browser-sites-status.png")
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .dark, to: "\(polish)/browser-sites-status-dark.png")
        m.browserSites = savedSites
        m.browserSiteChecks = [:]
        m.lang = .en
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(f6)/browser-on-en.png")
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .light, to: "\(f6)/browser-sites-en.png")
        m.lang = .tr
        m.browserProxyWanted = false
        m.browserSites = []
        renderWindow(BrowserSitesSheet(m: m), title: "Menfez", .dark, to: "\(f6)/browser-sites-empty-dark.png")
        m.helperVersion = 5
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(f6)/browser-old-helper.png")
        // Other apps (1.0.8): installed state is this Mac's, so rows may be dimmed.
        let f7 = "\(dir)/f7"
        try? FileManager.default.createDirectory(atPath: f7, withIntermediateDirectories: true)
        renderWindow(OtherAppsSheet(m: m), title: "Menfez", .light, to: "\(f7)/apps.png")
        renderWindow(OtherAppsSheet(m: m), title: "Menfez", .dark, to: "\(f7)/apps-dark.png")
        m.lang = .en
        renderWindow(OtherAppsSheet(m: m), title: "Menfez", .light, to: "\(f7)/apps-en.png")
        m.lang = .tr
        (m.browserProxyWanted, m.browserSites, m.helperVersion) = savedBrowser
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
        m.scopeChoice = .discord
        render(m, .dark, to: "\(dir)/dark-tunnel.png")
        render(m, .light, to: "\(dir)/tunnel.png")

        // The scope control, both choices side by side. Whole internet's card
        // shows the egress lookup, which now leaves through the server.
        let saved = m.report
        render(m, .light, to: "\(dir)/tunnel-scope-discord.png")
        m.scopeChoice = .all
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

        // Discord + sites: the three-way picker with the Sites chip, and the
        // list with a resolved, an unresolved and a still-unknown entry.
        m.helperVersion = HelperVersion.current
        m.scopeChoice = .sites
        m.sites = ["reddit.com", "archive.org", "pastebin.com"]
        m.siteCounts = ["reddit.com": 8, "archive.org": 0]
        m.sitesResolvedAt = Date().addingTimeInterval(-180)
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(dir)/sites-scope.png")
        renderWindow(SitesSheet(m: m), title: "Menfez", .light, to: "\(dir)/sites-editor.png")
        renderWindow(SitesSheet(m: m), title: "Menfez", .dark, to: "\(dir)/sites-editor-dark.png")
        m.sites = []
        renderWindow(SitesSheet(m: m), title: "Menfez", .light, to: "\(dir)/sites-editor-empty.png")
        m.siteCounts = [:]
        m.sitesResolvedAt = nil
        m.scopeChoice = .discord
        m.helperVersion = 0

        // Networks (feature 5): two remembered, on the first; then on an
        // unremembered network; then one that cannot be told apart.
        let savedNetworks = (m.networks, m.networkWatch)
        m.networks = [KnownNetwork(id: "home", name: "Ev", mode: .direct),
                      KnownNetwork(id: "school", name: "Okul ağı (kütüphane katı)", mode: .dpi),
                      KnownNetwork(id: "cafe", name: "Kafe", mode: .leave)]
        m.networkRead = true
        var watch = NetworkWatch()
        watch.observe("school")
        m.networkWatch = watch
        renderWindow(NetworksSheet(m: m, readsNetwork: false), title: "Menfez", .light, to: "\(dir)/networks.png")
        renderWindow(NetworksSheet(m: m, readsNetwork: false), title: "Menfez", .dark, to: "\(dir)/networks-dark.png")
        m.lang = .en
        m.networks[1].name = "School (library floor)"
        renderWindow(NetworksSheet(m: m, readsNetwork: false), title: "Menfez", .light, to: "\(dir)/networks-en.png")
        m.lang = .tr
        watch.observe("new")
        m.networkWatch = watch
        renderWindow(NetworksSheet(m: m, readsNetwork: false), title: "Menfez", .light, to: "\(dir)/networks-unknown.png")
        m.networks = []
        watch.observe(nil)
        m.networkWatch = watch
        renderWindow(NetworksSheet(m: m, readsNetwork: false), title: "Menfez", .dark, to: "\(dir)/networks-empty-dark.png")
        (m.networks, m.networkWatch) = savedNetworks

        // Kill switch on under the scope picker, then the tunnel dropped with
        // the block holding. A window: the switch is AppKit.
        m.helperVersion = HelperVersion.current
        m.killSwitchActive = true
        m.killSwitchProbe = { true }
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(dir)/killswitch-on.png")
        m.report?.health = Health(ok: false, code: .stale, ageS: 400)
        renderWindow(ContentView(m: m), title: "Menfez", .light, to: "\(dir)/killswitch-blocked.png")
        sideBySide("\(dir)/killswitch-on.png", "\(dir)/killswitch-blocked.png",
                   to: "\(dir)/killswitch.png")
        m.report = saved
        m.killSwitchActive = false
        m.killSwitchProbe = { false }

        // A leak test in Whole internet with DNS leaking to the router.
        renderView(LeakTestSheet(lang: .tr, lines: LeakTest.classify(LeakTest.Input(
            scope: .all, tunnelIface: "utun4", egressIP: "185.65.134.77", endpoint: "185.65.134.10",
            probeRouteIface: "utun4", resolvers: [("192.168.1.1", "en0")], hasPublicIPv6: true,
            ipv6Route: "blocked", killSwitch: true))),
                   .light, to: "\(dir)/leaktest.png")
        let servers = m.profiles
        m.profiles += [Profile(name: "bg-sof", file: "bg-sof.conf", endpoint: "94.156.1.20:51820",
                               country: "BG", display: "Bulgaristan")]
        renderView(ContentView(m: m).serverSheet, .light, to: "\(dir)/servers.png")
        m.profiles = servers

        // Keys in the Keychain (1.0.7): the offer with one key still in its
        // file, then everything moved (lock icons, the way back below).
        m.keychainSigned = true
        m.helperVersion = HelperVersion.current
        m.profiles = [Profile(name: "de-fra", file: "de-fra.conf", endpoint: "185.65.134.10:51820",
                              country: "DE", display: "Almanya", keychain: true),
                      Profile(name: "bg-sof", file: "bg-sof.conf", endpoint: "94.156.1.20:51820",
                              country: "BG", display: "Bulgaristan")]
        renderView(ContentView(m: m).serverSheet, .light, to: "\(dir)/keychain-offer.png")
        m.profiles[1].keychain = true
        renderView(ContentView(m: m).serverSheet, .light, to: "\(dir)/keychain-moved.png")
        sideBySide("\(dir)/keychain-offer.png", "\(dir)/keychain-moved.png", to: "\(dir)/keychain.png")
        m.profiles = servers
        m.helperVersion = 0

        // Feature 4: the server list after "Pick the fastest", and the
        // reconnect switches in Settings. In an f4/ subfolder.
        let f4 = dir + "/f4"
        try? FileManager.default.createDirectory(atPath: f4, withIntermediateDirectories: true)
        m.profiles = [Profile(name: "de-fra", file: "de-fra.conf", endpoint: "185.65.134.10:51820",
                              country: "DE", display: "Almanya"),
                      Profile(name: "bg-sof", file: "bg-sof.conf", endpoint: "94.156.1.20:51820",
                              country: "BG", display: "Bulgaristan"),
                      Profile(name: "nl-ams", file: "nl-ams.conf", endpoint: "vpn-nl-amsterdam-03.example.net:51820",
                              country: "NL", display: "Hollanda Amsterdam 3")]
        m.latencies = ["de-fra": .ms(42), "bg-sof": .ms(118), "nl-ams": .noReply]
        renderView(ContentView(m: m).serverSheet, .dark, to: "\(f4)/servers-latency-dark.png")
        renderView(ContentView(m: m).serverSheet, .light, to: "\(f4)/servers-latency-light.png")
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .dark, to: "\(f4)/settings-reconnect-dark.png")
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(f4)/settings-reconnect-light.png")
        m.lang = .en
        renderView(ContentView(m: m).serverSheet, .light, to: "\(f4)/servers-latency-en.png")
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(f4)/settings-reconnect-en.png")
        m.lang = .tr
        m.latencies = [:]
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
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .dark, to: "\(dir)/settings.png")
        // Settings with the notification switches, Turkish, light.
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(dir)/settings-notifications.png")
        m.hotKey = HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control | HotKeyCombo.option, key: "m")
        m.hotKeyRefused = true
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .light, to: "\(dir)/settings-shortcut.png")
        m.hotKey = nil
        m.hotKeyRefused = false

        // 1.0.9: every Settings tab, Turkish light, plus dark and English,
        // and the header dot on, off and mid-breath.
        let s9 = "\(dir)/109"
        try? FileManager.default.createDirectory(atPath: s9, withIntermediateDirectories: true)
        Updater.shared.available = true
        m.profiles = [Profile(name: "de-fra", file: "de-fra.conf", endpoint: "185.65.134.10:51820",
                              country: "DE", display: "Almanya"),
                      Profile(name: "bg-sof", file: "bg-sof.conf", endpoint: "94.156.1.20:51820",
                              country: "BG", display: "Bulgaristan")]
        for tab in SettingsTab.allCases {
            renderWindow(SettingsView(m: m, tab: tab), title: "Ayarlar", .light, to: "\(s9)/settings-\(tab.rawValue).png")
        }
        renderWindow(SettingsView(m: m, tab: .general), title: "Ayarlar", .dark, to: "\(s9)/settings-general-dark.png")
        renderWindow(SettingsView(m: m, tab: .tunnel), title: "Ayarlar", .dark, to: "\(s9)/settings-tunnel-dark.png")
        m.hotKey = HotKeyCombo(keyCode: 46, modifiers: HotKeyCombo.control | HotKeyCombo.option, key: "m")
        m.hotKeyRefused = true
        renderWindow(SettingsView(m: m, tab: .shortcut), title: "Ayarlar", .light, to: "\(s9)/settings-shortcut-taken.png")
        m.hotKeyRefused = false
        renderWindow(SettingsView(m: m, tab: .shortcut), title: "Ayarlar", .dark, to: "\(s9)/settings-shortcut-dark.png")
        m.lang = .en
        for tab in [SettingsTab.general, .tunnel, .shortcut] {
            renderWindow(SettingsView(m: m, tab: tab), title: "Settings", .light, to: "\(s9)/settings-\(tab.rawValue)-en.png")
        }
        m.lang = .tr
        m.hotKey = nil
        m.profiles = []
        Updater.shared.available = false
        let dots: [(Color, Bool, Double)] = [(Palette.success, true, 1), (Palette.success, true, 0.45),
                                             (Palette.warning, true, 1), (Palette.secondary, false, 1)]
        renderView(HStack(spacing: 24) {
                        ForEach(0..<dots.count, id: \.self) { i in
                            StatusDot(color: dots[i].0, pulsing: false, on: dots[i].1)
                                .frame(width: 15, height: 15).opacity(dots[i].2)
                        }
                    }.padding(16).background(Palette.bg),
                   .light, to: "\(s9)/header-dot.png")

        // Updates (1.0.6): the Settings switch beside the menu-bar items.
        Updater.shared.available = true
        renderWindow(HStack(alignment: .top, spacing: 0) {
                        SettingsView(m: m)
                        VStack(alignment: .leading, spacing: 6) { MenuBarContent(m: m) }
                            .buttonStyle(.plain).toggleStyle(MenuCheck())
                            .padding(12).frame(width: 300)
                    }, title: "Menfez", .light, to: "\(dir)/updates.png")

        // 1.0.11: the "new version ready" row, downloaded and waiting, and
        // its menu-bar item.
        let s11 = "\(dir)/1011"
        try? FileManager.default.createDirectory(atPath: s11, withIntermediateDirectories: true)
        Updater.shared.availableVersion = "1.0.12"
        Updater.shared.readyToInstall = true
        render(m, .light, to: "\(s11)/banner-tr-light.png")
        render(m, .dark, to: "\(s11)/banner-tr-dark.png")
        m.lang = .en
        render(m, .light, to: "\(s11)/banner-en-light.png")
        m.lang = .tr
        renderWindow(VStack(alignment: .leading, spacing: 6) { MenuBarContent(m: m) }
                        .buttonStyle(.plain).toggleStyle(MenuCheck())
                        .padding(12).frame(width: 300),
                     title: "Menfez", .light, to: "\(s11)/menu-tr.png")
        Updater.shared.availableVersion = nil
        Updater.shared.readyToInstall = false

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
