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
            version: "1.0.12",
            date: "2026-11-19",
            tr: [
                "DPI kartı daha derli toplu. Sayılar artık simgeli, renkli küçük kutucuklarda. DPI çalışırken adresin yanındaki yeşil nokta nefes alır.",
                "Mod seçici ve tünel kapsamı seçici yenilendi. Her seçeneğin bir simgesi var ve seçim yumuşakça kayar.",
                "Düğmeler her yerde aynı görünüyor. Asıl düğme dolu renkli, öbürleri ince kenarlı. Durdurma ve kaldırma düğmeleri kırmızıyla uyarır.",
                "Mod değişince kartlar yumuşak bir geçişle gelir. Hareketi azalt açıksa geçişler anında olur.",
                "Ayrıntılardaki Mod satırı artık tünelde seçtiğin kapsamı doğru gösteriyor.",
                "Bundan sonraki güncellemeler pencerenin üstündeki Güncelle satırından tek tıkla kurulur.",
            ],
            en: [
                "The DPI card is tidier. The numbers now sit in small coloured chips with icons. While DPI is working, a green dot next to the address breathes.",
                "The mode switch and the tunnel scope picker are new. Each option has an icon and the selection slides smoothly.",
                "Buttons look the same everywhere. The main button is filled, the others have a thin border. Stop and remove buttons warn you in red.",
                "When you change mode, the cards come in with a smooth transition. With Reduce Motion on, the change is instant.",
                "The Mode row in the details now shows the tunnel scope you chose.",
                "From now on, updates install with one click from the Update row at the top of the window.",
            ]),
        ChangelogEntry(
            version: "1.0.11",
            date: "2026-11-19",
            tr: [
                "Menfez açılınca yeni sürüm var mı diye bakar. Varsa arka planda indirir.",
                "Yeni sürüm hazır olunca pencerenin üstünde yazar. Güncelle'ye bir kez basman yeter. Menfez kurulur ve yeniden açılır.",
            ],
            en: [
                "When Menfez opens, it checks for a new version. If there is one, it downloads it in the background.",
                "When the new version is ready, Menfez says so at the top of the window. Press Update once and Menfez installs it and opens again.",
            ]),
        ChangelogEntry(
            version: "1.0.10",
            date: "2026-11-19",
            tr: [
                "Pencere açıkken Menfez daha az iş yapar. Böylece daha az pil ve işlemci harcar.",
                "Menfez arkada kalınca adının yanındaki nokta dinlenir. Pencereye dönünce yeniden nefes alır.",
            ],
            en: [
                "With the window open, Menfez does less work, so it uses less battery and CPU.",
                "When Menfez is in the background, the dot next to its name rests. It starts breathing again when you come back to the window.",
            ]),
        ChangelogEntry(
            version: "1.0.9",
            date: "2026-11-18",
            tr: [
                "Ayarlar yenilendi. Artık başlığı Ayarlar ve beş sekmesi var: Genel, Tünel, Bildirimler, Kısayol, Güncellemeler. Dil ve görünüm de Genel'de.",
                "Kısayol sekmesinde hazır kısayollar var. Birine tıkla, hemen kullanılır. Başka bir uygulama kullanıyorsa Menfez bunu söyler.",
                "Dili değiştirince uygulama menüleri hemen o dile geçer.",
                "Menfez açıkken adının yanındaki nokta yavaşça nefes alır. Hareketi azalt açıksa durur. Düğmeler basınca belli olur.",
                "Menfez arka planda daha az çalışır. Pencere kapalıyken ve tünel yokken neredeyse hiç işlemci kullanmaz.",
                "\"Tünel düşerse interneti kes\" açıkken Mac'in kendi içindeki bağlantılar artık takılmaz. Bunun için tünel bileşenini güncelle.",
                "Hata mesajları ne yapman gerektiğini de söylüyor. DPI açıkken üstteki satır sade bir dille durumu gösterir.",
                "DPI modunda Discord tek satırda görünür, sayılar Ayrıntılar altında durur. Tünel kurulumu neyin eksik olduğunu daha açık söyler ve gereken komutu tek tıkla kopyalarsın. Silme düğmelerine tıklamak daha kolay. Ayarlar en son baktığın sekmede açılır.",
            ],
            en: [
                "Settings is new. It is now titled Settings and has five tabs: General, Tunnel, Notifications, Shortcut and Updates. Language and look are in General.",
                "The Shortcut tab has ready-made shortcuts. Click one and it works right away. If another app uses it, Menfez tells you.",
                "When you change the language, the app menus switch to it right away.",
                "While Menfez is on, the dot next to its name breathes slowly. It stays still with Reduce Motion. Buttons now show when you press them.",
                "Menfez does less in the background. With the window closed and no tunnel, it uses almost no CPU.",
                "With \"Block internet if the tunnel drops\" on, connections inside your Mac no longer hang. This needs an updated tunnel component.",
                "Error messages now say what to do next. In DPI mode the line at the top shows the state in plain words.",
                "In DPI mode Discord shows up in one row and the numbers sit under Details. Tunnel setup says more clearly what is missing, and you can copy the command it needs in one click. Remove buttons are easier to click. Settings opens on the tab you used last.",
            ]),
        ChangelogEntry(
            version: "1.0.8",
            date: "2026-11-18",
            tr: [
                "Sunucular listesinde En hızlıyı seç: her sunucunun gecikmesini ölçer ve en hızlısına geçer. Tünel koparsa Menfez kendisi yeniden bağlanır. İstersen başka sunucuya da geçer.",
                "Ağa göre mod: Ayarlar > Ağlar'da bir ağı hatırlat, o ağa her bağlandığında Doğrudan, DPI ya da Tünel kendiliğinden açılsın. Konum izni istemez, Wi-Fi adını okumaz.",
                "Tarayıcıda da kullan: DPI modunda listene eklediğin siteler Safari ve Chrome'da da Menfez'den geçer, gerisi normal gider. Menfez kapanınca eski ayarın geri gelir. Bunun için tünel bileşenini güncelle.",
                "Başka uygulamalar: Slack, Signal ve Element'i Menfez'le açabilirsin. Telegram Desktop ve Spotify için girilecek adresi gösterir.",
                "DPI yetmiyorsa Ayar ara: Menfez bu ağ için işe yarayan bölme ayarını kendisi dener, bulursa o ağ için saklar.",
                "Discord satırı artık yanıt süresini gösteriyor. Tünelde gördüğün sayı gerçek gecikmeye çok daha yakın.",
                "DPI ekranı tek kartta toplandı. Discord satırı Discord'un DPI'dan geçip geçmediğini gösterir, tarayıcı listesi de her sitenin açılıp açılmadığını. Menfez artık iki kez açılmaz.",
                "Bir siteyi test et, seçtiğin DNS siteyi engelliyorsa bunu açıkça söyler.",
            ],
            en: [
                "Pick the fastest in the Servers list: measures each server's delay and switches to the fastest. If the tunnel drops, Menfez reconnects on its own and can switch server if you allow it.",
                "Mode by network: remember a network in Settings > Networks and Direct, DPI or Tunnel turns on by itself whenever you join it. No location permission, no Wi-Fi name read.",
                "Use in browsers too: in DPI mode the sites on your list go through Menfez in Safari and Chrome as well. Everything else goes as usual. Your old setting comes back when Menfez closes. This needs an updated tunnel component.",
                "Other apps: open Slack, Signal and Element with Menfez. For Telegram Desktop and Spotify it shows the address to type in.",
                "If DPI isn't enough, Find a setting: Menfez tries split settings for this network itself and keeps the one that works.",
                "The Discord row now shows response time instead of the full page load, so the number is much closer to your real latency.",
                "The DPI screen is now one card. The Discord row shows whether Discord goes through DPI, and the browser list shows whether each site opens. Menfez no longer opens twice.",
                "Test a site now says so plainly when the DNS you chose blocks the site.",
            ]),
        ChangelogEntry(
            version: "1.0.7",
            date: "2026-11-18",
            tr: [
                "Sunucu anahtarların artık Anahtar Zinciri'nde durabilir. Sunucular listesinde bir kez sorar. Kabul edersen anahtar diskte düz metin olarak kalmaz.",
                "Anahtarı Anahtar Zinciri'nde olan sunucunun yanında kilit var. Sonradan eklediğin sunucular da oraya gider.",
                "Geri almak istersen: Sunucular > Anahtarları dosyaya geri yaz. 1.0.6'ya dönmeden önce bunu yap, yoksa tünel açılmaz.",
                "Hakkında'da Üçüncü taraf lisansları var. Bu özellik için tünel bileşenini güncellemen gerekir. Menfez'deki Güncelle düğmesine bas.",
            ],
            en: [
                "Your server keys can now live in Keychain. The Servers list asks once. Say yes and keys don't sit on disk as plain text.",
                "A server whose key is in Keychain shows a lock. Servers you add later go there too.",
                "To undo it: Servers > Write keys back to files. Do this before going back to 1.0.6, or the tunnel won't start.",
                "About now has Third-party licenses. This needs an updated tunnel component. Press Update in Menfez.",
            ]),
        ChangelogEntry(
            version: "1.0.6",
            date: "2026-11-18",
            tr: [
                "Menfez artık kendini güncelleyebilir. Yeni sürüm çıkınca sorar, tek tıkla kurar ve yeniden açılır.",
                "Menü çubuğunda ve Hakkında'da Güncellemeleri denetle var. Kendiliğinden denetlemeyi Ayarlar'dan kapatabilirsin.",
                "Güncelleme açık tüneli kapatmaz. Tünel düşerse interneti kes açıksa Menfez yeniden açılınca yine devreye girer.",
                "Tüneli kur'a bastıktan sonra Tünel düğmesi Menfez'i yeniden başlatmadan çalışıyor.",
            ],
            en: [
                "Menfez can now update itself. When a new version is out it asks, installs with one click and reopens.",
                "Check for Updates is in the menu bar and in About. You can turn automatic checks off in Settings.",
                "An update doesn't close an open tunnel. With Block internet if the tunnel drops on, it comes back on when Menfez reopens.",
                "After Set up tunnel, the Tunnel button works without restarting Menfez.",
            ]),
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
                "New tunnel option: Discord + sites. The sites on your list go through the tunnel along with Discord. Everything else uses your normal internet.",
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
