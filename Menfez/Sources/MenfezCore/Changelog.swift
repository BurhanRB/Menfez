// Changelog.swift — the "What's new" list in the About panel.
//
// Kept in MenfezCore so a test can check it against the release version and
// that every entry says the same number of things in both languages.
// Newest entry first. Every release bumps the patch number (1.0.0, 1.0.1, …)
// and adds an entry here; ChangelogTests holds that rule. Written for people who do not know what DNS or a proxy is.

public struct ChangelogEntry: Sendable {
    public let version: String
    public let date: String   // yyyy-MM-dd
    public let tr: [String]
    public let en: [String]

    public init(version: String, date: String, tr: [String], en: [String]) {
        self.version = version; self.date = date; self.tr = tr; self.en = en
    }
}

public enum Changelog {
    public static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.0.0",
            date: "2026-11-17",
            tr: [
                "Discord artık \"Güncellemeler denetleniyor\" ekranında takılı kalmıyor.",
                "DPI modunda Discord güncellemeleri kendi sunucun üzerinden iner.",
                "Hangi DNS'in kullanılacağını seçebilirsin. İstersen DNS de tünelden geçer.",
                "Kendi WireGuard sunucunu ekleyebilir, adını ya da dosyasını değiştirebilir, silebilirsin. Silinen sunucu Çöp Sepeti'ne gider.",
                "Tünel açıkken sunucunun IP adresi, konumu ve sağlayıcısı görünür.",
                "Menü çubuğunda simgesi var ve bilgisayar açılınca kendiliğinden başlayabilir.",
                "Sorun bildirmek için hata kaydını kaydedebilirsin. Kayıtta IP adresin ve anahtarların gizlenir.",
                "Yeni görünüm: buz beyazı açık tema, yeni simge ve daha anlaşılır yardım.",
            ],
            en: [
                "Discord no longer gets stuck on \"Checking for updates\".",
                "In DPI mode, Discord updates come through your own server.",
                "You can choose which DNS to use, and send DNS through the tunnel too.",
                "Add your own WireGuard server, rename it, replace its file or delete it. A deleted server goes to the Trash.",
                "While the tunnel is on, you see your server's IP address, location and provider.",
                "It has a menu bar icon and can start on its own when you log in.",
                "To report a problem, save the debug log. Your IP address and keys are hidden in it.",
                "New look: an ice-white light theme, a new icon and clearer help.",
            ]),
    ]
}
