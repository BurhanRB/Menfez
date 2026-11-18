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
            version: "1.0.5",
            date: "2026-11-18",
            tr: [
                "Tünelde yeni seçenek: Discord + siteler. Discord'un yanında listene eklediğin siteler de tünelden gider, gerisi normal internetinden.",
                "Siteleri tünel kartındaki Siteler düğmesinden ekle ya da sil. Her sitenin yanında kaç adres bulunduğu yazar, bulunamazsa söyler.",
                "Sitelerin adresleri değişirse Menfez kendisi yeniler. Tünel düşerse interneti kes açıksa bu siteler de kesilir.",
                "Bu seçenek için tünel bileşenini güncellemen gerekir. Menfez'deki Güncelle düğmesine bas.",
            ],
            en: [
                "New tunnel option: Discord + sites. The sites on your list go through the tunnel along with Discord; everything else uses your normal internet.",
                "Add or remove sites with the Sites button on the tunnel card. Each site shows how many addresses were found, or says if none were.",
                "If a site's addresses change, Menfez updates them by itself. With Block internet if the tunnel drops on, these sites are cut too.",
                "This option needs an updated tunnel component. Press Update in Menfez.",
            ]),
        ChangelogEntry(
            version: "1.0.4",
            date: "2026-11-18",
            tr: [
                "Tünel düşerse interneti kes: açıksa tünel koptuğunda hiçbir şey tünel dışından çıkmaz. Tek tıkla Yeniden bağlan ya da Engeli kaldır.",
                "Sızıntı testi: IP adresin, DNS ve IPv6 gerçekten tünelden mi gidiyor, tünel kartından bak.",
                "Klavye kısayolu: Ayarlar'dan bir tuş kaydet, Doğrudan ile son modun arasında geç. İzin istemez.",
                "Sunucu yokken Tünel'e basıp sunucu eklersen yeni sunucu seçilir ve tünel kayıtlı kapsamla (Tüm internet ya da Sadece Discord) açılır.",
                "Tünel özellikleri için tünel bileşenini güncellemen gerekir. Menfez'deki Güncelle düğmesine bas.",
            ],
            en: [
                "Block internet if the tunnel drops: when on, nothing leaves outside the tunnel after it drops. One click to Reconnect or Unblock.",
                "Leak test: check from the tunnel card that your IP address, DNS and IPv6 really go through the tunnel.",
                "Keyboard shortcut: record a key in Settings to switch between Direct and your last mode. No permission needed.",
                "Pressing Tunnel with no server and then adding one now picks the new server and starts the tunnel with your saved scope (Whole internet or Discord only).",
                "The tunnel features need an updated tunnel component. Press Update in Menfez.",
            ]),
        ChangelogEntry(
            version: "1.0.3",
            date: "2026-11-18",
            tr: [
                "İlk açılışta kısa bir rehber: DPI nedir, Menfez ne yapar, kendi sunucunla tünel. Atlanabilir, Yardım'dan yeniden açılır.",
                "Bildirimler: tünel düşünce ya da geri gelince, silinen sunucu yüzünden tünel kapanınca, DPI durunca, tünel bileşeni eskiyince.",
                "Her bildirim Ayarlar'dan ayrı ayrı kapatılabilir. Pencere öndeyken bildirim gelmez, aynı uyarı art arda gelmez.",
                "Bir siteyi test et: site adını yaz, Menfez doğrudan, DPI ile ya da tünelle açılıyor mu birkaç saniyede söyler.",
            ],
            en: [
                "A short guide on first launch: what DPI is, what Menfez does, and the tunnel with your own server. Skippable, and you can reopen it from Help.",
                "Notifications: when the tunnel drops or comes back, when a removed server closes the tunnel, when DPI stops, and when the tunnel component is out of date.",
                "You can turn each notification off in Settings. None arrive while the window is in front, and the same alert doesn't repeat.",
                "Test a site: type a site name and Menfez tells you in a few seconds whether it opens directly, with DPI or through the tunnel.",
            ]),
        ChangelogEntry(
            version: "1.0.2",
            date: "2026-11-18",
            tr: [
                "Silinen bir sunucunun tüneli artık açık kalmıyor. Menfez böyle bir tüneli kendisi kapatır ve haber verir.",
                "Sunucunun adını ya da dosyasını değiştirince tünel doğru sunucuyu gösteriyor.",
                "Tüneli kaldır düğmesi Yardım'da da var. Menü çubuğuna Ayarlar eklendi.",
                "Tünelde Sadece Discord ya da Tüm internet seçilebilir. Tüm internet'te Safari ve diğer uygulamalar da sunucunun IP'siyle çıkar, DNS de tünelden gider.",
                "Silinen sunucunun boşta kalan tüneli de tamamen kapanıyor. Tünel bileşeni eskiyse Menfez Güncelle düğmesi gösterir.",
            ],
            en: [
                "A deleted server's tunnel no longer stays on. Menfez closes such a tunnel itself and tells you.",
                "After you rename or replace a server, the tunnel shows the right server.",
                "Remove tunnel is now in Help too, and the menu bar has Settings.",
                "Tunnel can carry Discord only or the whole internet. With Whole internet, Safari and every other app go out with the server's IP, and DNS goes through the tunnel too.",
                "A deleted server's idle tunnel now shuts down completely. If the tunnel component is out of date, Menfez shows an Update button.",
            ]),
        ChangelogEntry(
            version: "1.0.1",
            date: "2026-11-17",
            tr: [
                "Tüneli kur düğmesi: macOS şifre penceresiyle kurulur, Terminal gerekmez.",
                "Tüneli Ayarlar'dan tek düğmeyle kaldırabilirsin.",
                "Discord ayrıntı penceresi hemen açılıyor ve DPI yolundan güncelleniyor.",
                "Menfez, Discord'un ayar dosyasına en fazla bir kez dokunuyor. Tam Disk Erişimi istemiyor.",
            ],
            en: [
                "Set up tunnel button: macOS asks for your password, no Terminal needed.",
                "You can remove the tunnel from Settings with one button.",
                "The Discord details window opens at once and refreshes through DPI.",
                "Menfez touches Discord's settings file at most once and no longer asks for Full Disk Access.",
            ]),
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
