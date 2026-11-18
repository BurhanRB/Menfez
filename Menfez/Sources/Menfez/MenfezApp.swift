import MenfezCore
// Menfez — native macOS control panel for the WireGuard split tunnel.
//
// Architecture
//   This file is the whole UI. It never touches the routing table, WireGuard
//   or DNS itself: every privileged action is a call to `menfez-route`
//   through passwordless sudo, and every value shown comes from that script's
//   JSON. Keeping one privileged entry point is what makes the rollback
//   guarantees in that script meaningful.
//
//   The backend is Python today because it was already written, tested and
//   proven on this machine. Moving it to Swift is a separate step; the UI does
//   not care, it only speaks JSON.
//
// Localisation
//   Turkish and English, switchable at runtime, remembered in
//   ~/Library/Application Support/Menfez/ui.json.

import SwiftUI
import AppKit
import ServiceManagement
import Foundation
import MenfezCore

// MARK: - Localisation

enum Lang: String {
    case tr, en

    var flag: String { self == .tr ? "🇹🇷" : "🇬🇧" }
    var label: String { self == .tr ? "Türkçe" : "English" }
}

struct L {
    let lang: Lang

    private static let table: [Lang: [String: String]] = [
        .tr: [
            "app": "Menfez",
            "tagline": "Engelli ağda Discord'a bağlanmak için",
            "m_discord": "Sadece Discord",
            "m_all": "Tüm internet",
            "scope_label": "Tünelden geçen",
            "helper_outdated": "Tünel bileşeni bu sürümden eski. Yeni özellikler için güncelle.",
            "helper_update": "Güncelle",
            "scope_discord_hint": "Diğer uygulamalar normal internetini kullanır.",
            "scope_all_hint": "Safari ve tüm uygulamalar sunucunun IP'siyle çıkar.",
            "m_dpi": "DPI",
            "m_off": "Kapalı",
            "m_updates": "Discord güncellemeleri",
            "updates_tunnel": "Discord güncellemelerini tünelden indir",
            "updates_tunnel_note": "DPI modunda yalnızca Discord güncellemeleri ve DNS tünelden geçer. Geri kalan her şey DPI ile gider.",
            "updates_tunnel_on": "Discord güncellemeleri tünelden geliyor",
            "updates_tunnel_failed": "Güncellemeler için tünel açılamadı. Discord \"Güncellemeler denetleniyor\" ekranında kalabilir.",
            "mode_direct": "Doğrudan",
            "mode_dpi": "DPI",
            "mode_tunnel": "Tünel",
            "mode_direct_hint": "Menfez araya girmez, bağlantın olduğu gibi kalır",
            "mode_dpi_hint": "Discord'u Menfez üzerinden açar. Yönetici şifresi gerekmez.",
            "mode_tunnel_hint": "Trafiğini kendi WireGuard sunucundan geçirir. Bir kez kurulum ister.",
            "dpi_enable_discord": "Discord'u aç",
            "dpi_enable_hint": "Menfez önce proxy'yi başlatır, sonra Discord'u açar",
            "dpi_enable_from_tunnel_hint": "Tüneli kapatır, DPI'a geçer ve Discord'u açar",
            "dpi_launch_again": "Discord'u yeniden aç",
            "dpi_launch_again_hint": "DPI açık. Discord kapanıp yeniden açılır.",
            "dpi_no_root_note": "Yönetici şifresi gerekmez. Proxy, Menfez'in içinde çalışır.",
            "tunnel_ready": "Tünel kullanıma hazır.",
            "tunnel_ready_pick": "Tünel hazır, sunucu seçmen gerekiyor.",
            "tunnel_ready_add": "Tünel hazır, sunucu eklemen gerekiyor.",
            "direct_tunnel_present": "WireGuard tüneli açık, DPI kapalı",
            "tunnel_setup": "Kur",
            "tunnel_install": "Tüneli kur",
            "tunnel_remove": "Tüneli kaldır",
            "tunnel_installed": "Kurulu",
            "menu_settings": "Ayarlar…",
            "tunnel_install_running": "Kuruluyor. macOS yönetici şifreni soracak.",
            "tunnel_remove_running": "Kaldırılıyor. macOS yönetici şifreni soracak.",
            "tunnel_install_done": "Tünel kuruldu. Tünel modunu seçebilirsin.",
            "tunnel_remove_done": "Tünel kaldırıldı. DPI çalışmaya devam eder.",
            "tunnel_install_cancelled": "İptal edildi. Hiçbir şey değişmedi.",
            "tunnel_install_failed": "Kurulum tamamlanmadı: {detail}",
            "tunnel_remove_failed": "Kaldırma tamamlanmadı: {detail}",
            "tunnel_remove_leave_first": "Kaldırmadan önce Tünel modundan çık.",
            "help_setup_terminal": "Terminal'i tercih edersen:",
            "tunnel_install_need_wg": "Önce WireGuard araçları gerekiyor. Terminal'de çalıştır: brew install wireguard-tools wireguard-go bash",
            "tunnel_needs_setup": "Tüneli kullanmak için bir kez kurulum yapman gerekiyor.",
            "help_copy_command": "Komutu kopyala",
            "dpi_title": "DPI",
            "dpi_off": "kapalı",
            "dpi_off_state": "DPI kapalı, bağlantın doğrudan gidiyor",
            "dpi_split": "bölündü",
            "dpi_passthrough": "dokunulmadı",
            "dpi_open": "açık",
            "dpi_refused": "reddedildi",
            "dpi_at": "ilk paketi {n}. baytta bölüyor",
            "dpi_probe": "Şimdi test et",
            "dpi_probing": "test ediliyor…",
            "dpi_stop": "Durdur",
            "dpi_quit_first": "Discord açıksa önce kapat. Menfez ayarı ancak Discord açılırken verebilir.",
            "discord_launch": "Discord'u Menfez ile aç",
            "discord_launched": "Discord açıldı (proxy 127.0.0.1:{port})",
            "discord_settings_denied": "Discord'un ayar dosyasına yazamadım. Discord \"Güncellemeler denetleniyor\" ekranında kalabilir. macOS izin isterse ver, sonra Discord'u kapatıp yeniden aç.",
            "discord_settings_hint": "macOS, Menfez'in Discord'un ayar dosyasına yazmasını engelledi. Discord \"Güncellemeler denetleniyor\" ekranında bekleyebilir. Menfez bunu bir daha kendiliğinden denemez. Tekrar dene'ye basınca macOS izin sorarsa ver. Kendi sunucunu eklersen bu izne gerek kalmaz.",
            "discord_settings_retry": "Tekrar dene",
            "dpi_port_changed": "Proxy portu değişti. Discord açıksa kapat ve Menfez'den yeniden aç.",
            "st_direct": "Menfez kapalı, bağlantın doğrudan gidiyor",
            "st_dpi_on": "DPI açık (127.0.0.1:{port})",
            "st_tunnel_on": "Tünel açık",
            "tunnel_lost": "Tünel koptu. Trafiğin şu an şifresiz gidiyor olabilir.",
            "tunnel_lost_blocked": "Tünel koptu. Engel açık, trafik dışarı çıkmıyor.",
            "tunnel_helper_missing": "Tünel için bir kez kurulum gerekiyor. DPI kurulumsuz çalışır.",
            "tunnel_not_installed": "Tünel bileşeni kurulu değil. Tüneli kur'a bas.",
            "app_update_check": "Güncellemeleri denetle…",
            "app_update_auto": "Güncellemeleri kendiliğinden denetle",
            "helper_no_reply": "yardımcı program yanıt vermedi",
            "launch_proxyNotRunning": "Önce DPI'ı aç. Proxy çalışmıyor.",
            "launch_invalidPort": "{port} portu kullanılamıyor",
            "launch_alreadyRunning": "Discord zaten açık. Önce kapat, Menfez ayarı ancak açılışta verebilir.",
            "launch_notInstalled": "Discord, Uygulamalar klasöründe yok",
            "launch_openFailed": "Discord açılamadı: {what}",
            "discord_restart_title": "Discord yeniden başlatılsın mı?",
            "discord_restart_body": "Discord hâlâ kapattığın proxy'yi kullanıyor. Yeniden başlamadan bağlanamaz.",
            "discord_restart_yes": "Yeniden başlat",
            "discord_restart_no": "Şimdi değil",
            "discord_restart_later": "Discord'un bağlanması için onu yeniden başlat.",
            "discord_restarted": "Discord proxy'siz yeniden açıldı",
            "probe_working": "Doğrudan bağlantı engelli, DPI ile geçiyor. DPI işe yarıyor.",
            "probe_notNeeded": "Doğrudan bağlantı çalışıyor. Bu ağ şu an engellemiyor, DPI'a gerek yok.",
            "probe_notHelping": "İkisi de bağlanamadı. Bu ağda DPI yetmiyor, tüneli dene.",
            "probe_dnsBlocked": "İkisi de bağlanamadı, adres çözülemedi. DNS engelli. DNS'i değiştirip tekrar dene.",
            "probe_proxyBroken": "Doğrudan bağlantı çalışıyor ama proxy çalışmıyor. Sorun Menfez'in proxy'sinde.",
            "probe_proxyOff": "Proxy kapalı, karşılaştıracak bir şey yok.",
            "probe_needs_proxy": "Önce DPI'ı aç. Test proxy üzerinden yapılıyor.",
            "probing": "ağ test ediliyor…",
            "f_egress": "Şu anki IP",
            "f_where": "Konum",
            "f_isp": "Sağlayıcı",
            "f_server": "Sunucu",
            "f_dns": "DNS",
            "f_mode": "Mod",
            "f_routes": "Rotalar",
            "f_handshake": "Son bağlantı",
            "f_transfer": "Veri",
            "f_gateway": "Ağ geçidi",
            "pill_server": "Sunucu:",
            "srv_edit": "Düzenle",
            "srv_delete": "Sil",
            "srv_name": "Sunucu adı",
            "srv_save": "Kaydet",
            "srv_cancel": "Vazgeç",
            "srv_replace": "Config'i değiştir…",
            "srv_delete_q": "{name} silinsin mi?",
            "srv_delete_body": "Bu sunucunun ayar dosyası Çöp Sepeti'ne taşınır. Tünel şu an bu sunucuyu kullanıyorsa önce Doğrudan moda geçilir.",
            "srv_deleted": "Silindi: {name}",
            "srv_delete_failed": "Silinemedi: {name}",
            "tunnel_orphan_closed": "Sunucu silindiği için tünel kapatıldı",
            "srv_not_in_list": "listede yok",
            "srv_renamed": "Yeni adı: {name}",
            "srv_bad_name": "Bu ad olmaz. Harf, rakam, boşluk, - ya da _ kullan (en çok 64).",
            "srv_name_taken": "Bu adda bir sunucu zaten var.",
            "srv_replaced": "Config yenilendi: {name}",
            "kc_offer_title": "Sunucu anahtarlarını Anahtar Zinciri'ne taşı",
            "kc_offer_body": "Anahtar diskte düz metin olarak kalmaz.",
            "kc_move": "Taşı",
            "kc_not_now": "Şimdi değil",
            "kc_move_link": "Anahtarları Anahtar Zinciri'ne taşı",
            "kc_restore": "Anahtarları dosyaya geri yaz",
            "kc_in_keychain": "Anahtar, Anahtar Zinciri'nde",
            "kc_moved": "Anahtarlar Anahtar Zinciri'nde ({n})",
            "kc_move_failed": "{n} anahtar taşınamadı; o dosyalar değişmedi.",
            "kc_restored": "Anahtarlar dosyalara geri yazıldı ({n})",
            "kc_restore_failed": "{n} anahtar geri yazılamadı; o dosyalar değişmedi.",
            "kc_failed": "Anahtar Zinciri'ne erişilemedi; tünel açılamadı",
            "f_discord": "Discord",
            "up": "Tünel açık",
            "down": "Tünel kapalı, bağlantın doğrudan gidiyor",
            "off_state": "Menfez devrede değil",
            "unhealthy": "Tünel açık ama düzgün çalışmıyor",
            "routes_lost": "Rotalar silinmiş, trafik gitmiyor",
            "checking": "kontrol ediliyor…",
            "switching": "Geçiliyor: {what}…",
            "mode_set": "Mod: {what}",
            "server_set": "Sunucu: {what}",
            "dns_set": "DNS: {what}",
            "failed": "Yapılamadı: {what}",
            "reconnected_last": "Son kullandığın sunucuya bağlandı: {what}",
            "choose_server": "Yeniden başlatınca tünel ayarı silindi. Bir sunucu seç.",
            "no_profiles": "Henüz sunucu yok. Kendi WireGuard .conf dosyanı ekle.",
            "now": "az önce",
            "last_updated": "Son güncelleme {time}",
            "unused": "kullanılmıyor",
            "none": "yok",
            "auto": "Otomatik",
            "never": "hiç",
            "active_n": "{n}/{total} açık",
            "ok_ms": "açılıyor, {ms} ms",
            "ok": "açılıyor",
            "blocked": "engelli",
            "dns_blocked": "DNS engelli",
            "conn_failed": "bağlanamadı",
            "proxy_failed": "proxy ulaşamadı",
            "tls_blocked": "TLS engelli",
            "http": "HTTP {code}",
            "refresh": "Yenile",
            "servers": "Sunucu seç",
            "dns_title": "DNS seç",
            "close": "Kapat",
            "working": "yükleniyor…",
            "testing": "DNS hızları ölçülüyor…",
            "automatic": "Otomatik",
            "dns_note": "Süreler şimdi ölçüldü",
            "doh_title": "Menfez'in kullandığı DNS",
            "doh_note": "Şifreli sorulur (DoH)",
            "dns_tunnel": "DNS'i tünelden geçir",
            "dns_tunnel_note": "Sadece Discord modunda DNS sorguların da tünelden gider. Modemin DNS'i bunun dışında kalır.",
            "dns_tunnel_private": "DNS'in şu an modemde (ör. 192.168.1.1), bu yüzden tünelden geçmiyor. Yukarıdan 1.1.1.1 gibi bir DNS seç.",
            "dns_routes_updated": "Ağ değişti, DNS rotaları yenilendi",
            "fastest": "en hızlı",
            "unreachable": "yanıt yok",
            "s": "{n} sn önce",
            "m": "{n} dk önce",
            "h": "{n} sa önce",
            "import_conf": "Sunucu ekle…",
            "import_prompt": "WireGuard .conf dosyanı seç",
            "any_provider": "WireGuard veren her sağlayıcının .conf dosyası çalışır. Menfez dosyayı kendi klasörüne kopyalar, onu yalnızca senin hesabın okuyabilir.",
            "import_ok": "Eklendi: {what}",
            "byo_conf_short": "Kendi WireGuard .conf dosyanı ekle",
            "byo_conf": "Tünel için kendi WireGuard dosyan (.conf) gerekir. Menfez sunucu vermez.",
            "menu_open": "Pencereyi aç",
            "menu_quit": "Çık",
            "launch_at_login": "Mac açılınca başlat",
            "launch_at_login_failed": "Açılışta başlatma ayarlanamadı: {what}",
            "login_move_first": "Önce Menfez'i Uygulamalar klasörüne taşı.",
            "login_needs_approval": "Sistem Ayarları > Genel > Giriş Öğeleri'nden Menfez'e izin ver.",
            "det_ip": "IP ayrıntıları",
            "det_routes": "Rotalar",
            "det_dns": "DNS",
            "det_tunnel": "Tünel",
            "det_discord": "Discord",
            "copied": "kopyalandı",
            "help_hint": "Yardım",
            "about_hint": "Hakkında",
            "whatsnew_hint": "Yenilikler",
            "whatsnew_version": "Sürüm {v}",
            "whatsnew_current": "Şu anki",
            "appearance": "Görünüm",
            "app_system": "Sistem",
            "app_dark": "Koyu",
            "app_light": "Açık",
            "about_version": "sürüm {v}",
            "donate_hint": "Bir çay ısmarla (burhanrb.com)",
            "export_log": "Günlüğü kaydet…",
            "log_exported": "Hata kaydı kaydedildi",
            "log_export_failed": "Hata kaydı kaydedilemedi",
            "help_title": "Yardım",
            "help_modes": "Üç mod var",
            "help_direct": "Doğrudan: Menfez hiçbir şey yapmaz, internetin normal çalışır.",
            "help_dpi": "DPI: Discord'u engele takılmadan açar. Şifre ya da sunucu gerekmez.",
            "help_tunnel": "Tünel: İnternet trafiğin kendi sunucundan geçer.",
            "help_which_title": "Hangisini seçmeliyim?",
            "help_which": "Önce DPI modunu dene. Discord yine açılmazsa tünele geç. Discord'a ihtiyacın yoksa Doğrudan'da kal.",
            "help_conf_title": "Kendi sunucunu ekle",
            "help_conf": "Menfez sunucu vermez. WireGuard sağlayıcının panelinden bir .conf dosyası indir ve buradan ekle.",
            "help_discord_title": "Discord açılmıyorsa",
            "help_discord": "Discord'u Cmd+Q ile tamamen kapat ve Menfez'deki düğmeyle yeniden aç. Olmazsa DNS'i 1.1.1.1 yap. Yine olmazsa tüneli dene.",
            "help_discord_wait": "Discord yaklaşık 10 saniye bekleyip yüklü sürümüyle açılabilir. Güncellemeler engel olmayan bir ağdayken ya da kendi sunucunu eklediğinde gelir.",
            "help_setup_title": "Tünel kurulumu (bir kez)",
            "help_setup": "Yalnızca tünel için gerekir. Önce Terminal'de WireGuard araçlarını kur: brew install wireguard-tools wireguard-go bash. Sonra Tüneli kur'a bas, macOS yönetici şifreni sorar. Menfez'i güncelleyince yeniden bas.",
            "help_log": "Sorun sürerse hata kaydını kaydet ve GitHub'da bildirirken ekle. Kayıtta IP adresin ve anahtarların gizlenir.",
            "about_author": "Yapan",
            "about_web": "Web sitesi",
            "about_support": "Destek ol",
            "about_license": "Açık kaynak, Apache-2.0 lisanslı.",
            "about_licenses": "Üçüncü taraf lisansları",
            "dt_IP": "IP",
            "dt_Reverse DNS": "Ters DNS",
            "dt_City": "Şehir",
            "dt_Region": "Bölge",
            "dt_Country": "Ülke",
            "dt_Postal": "Posta kodu",
            "dt_Timezone": "Saat dilimi",
            "dt_Coordinates": "Koordinat",
            "dt_Network": "Ağ",
            "dt_Provider": "Sağlayıcı",
            "dt_Routing": "Yol",
            "dt_Resolver": "DNS sunucusu",
            "dt_Interface": "Arayüz",
            "dt_Mode": "Mod",
            "dt_Endpoint": "Sunucu adresi",
            "dt_Handshake": "Son bağlantı",
            "dt_Received": "Gelen",
            "dt_Sent": "Giden",
            "dt_active": "var",
            "dt_missing": "yok",
            "dt_MISSING": "YOK",
            "dt_no answer": "yanıt yok",
            "dt_never": "hiç",
            "dt_unreachable": "ulaşılamıyor",
            "dt_automatic (from DHCP)": "otomatik (modemden)",
            "dt_on-link, no gateway": "yerel ağda, ağ geçidi yok",
            "dt_pinned via": "{what} üzerinden sabit",
            "dt_via": "{iface}, {gateway} üzerinden",
            "dt_host": "sunucu {what}",
            "dt_unreachable_why": "ulaşılamıyor ({what})",
            "notify_title": "Bildirimler",
            "notify_tunnelDropped_setting": "Tünel düşünce ve geri gelince",
            "notify_serverRemoved_setting": "Sunucu silinip tünel kapanınca",
            "notify_dpiStopped_setting": "DPI kendiliğinden durunca",
            "notify_helperUpdate_setting": "Yardımcı güncellenmeli olunca",
            "notify_note": "Menfez penceresi öndeyken bildirim gelmez. Aynı uyarı 5 dakikada bir kereden sık gelmez.",
            "notify_tunnelDropped_title": "Tünel düştü",
            "notify_tunnelDropped_body": "Trafiğin şu an tünelden geçmiyor. Menfez'i açıp bak.",
            "notify_tunnelRestored_title": "Tünel geri geldi",
            "notify_tunnelRestored_body": "Trafiğin yeniden tünelden geçiyor.",
            "notify_serverRemoved_title": "Tünel kapatıldı",
            "notify_serverRemoved_body": "Kullandığın sunucu listeden silindiği için tüneli kapattım.",
            "notify_dpiStopped_title": "DPI durdu",
            "notify_dpiStopped_body": "DPI beklenmedik şekilde durdu. Discord bağlanamayabilir. Menfez'den yeniden aç.",
            "notify_helperUpdate_title": "Tünel yardımcısı eski",
            "notify_helperUpdate_body": "Tünelin düzgün çalışması için yardımcıyı güncelle. Menfez'deki Güncelle düğmesine bas.",
            "sitetest_open": "Bir siteyi test et…",
            "sitetest_title": "Bir siteyi test et",
            "sitetest_intro": "Site adını ya da adresini yaz. Menfez siteyi doğrudan ve DPI ile aynı anda dener, birkaç saniyede sonucu söyler. Tüm internet tüneli açıksa tünelle dener.",
            "sitetest_placeholder": "ornek.com",
            "sitetest_run": "Test et",
            "sitetest_running": "Deneniyor",
            "sitetest_err_empty": "Önce bir site adı yaz.",
            "sitetest_err_notAName": "Bu bir site adına benzemiyor. Şöyle yaz: ornek.com",
            "sitetest_err_address": "IP adresi değil, site adı yaz (ör. ornek.com).",
            "sitetest_err_local": "Bu ev ağındaki ya da bu bilgisayardaki bir ad. Yalnız internetteki siteler test edilir.",
            "sitetest_err_port": "Yalnız normal web adresleri test edilir. Adresteki :port kısmını sil.",
            "sitetest_path_direct": "Doğrudan",
            "sitetest_path_dpi": "DPI ile",
            "sitetest_path_tunnel": "Tünel ile",
            "sitetest_opens": "Açılıyor",
            "sitetest_fails": "Açılmıyor",
            "sitetest_timedOut": "Cevap yok",
            "sitetest_notFound": "Ad bulunamadı",
            "sitetest_sum_opensDirect": "Bu site engelli değil, doğrudan açılıyor.",
            "sitetest_sum_opensWithDPI": "Bu site engelli ama DPI ile açılıyor. Menfez DPI'ı şimdilik yalnız Discord için kullanıyor; tarayıcında açmak için Tüm internet tünelini kullan.",
            "sitetest_sum_opensWithTunnel": "Bu site tünelle açılıyor.",
            "sitetest_sum_opensNowhere": "Bu site ne doğrudan ne DPI ile açılıyor. Site kapalı olabilir ya da engel daha sıkı. Kendi sunucun varsa Tüm internet tünelini dene.",
            "sitetest_sum_opensNowhereTunnel": "Bu site tünelle de açılmıyor. Site şu an kapalı olabilir.",
            "sitetest_sum_notFound": "Bu ad bulunamadı. Yazımı kontrol et.",
            "sitetest_sum_refused": "Bu ad ev ağındaki bir adrese çıkıyor, test etmedim.",
            "sitetest_tunnel_discord_only": "Tünel şu an yalnız Discord'u taşıyor, bu yüzden site tünelle denenmedi.",
            "help_sitetest_title": "Bir site açılmıyorsa",
            "help_sitetest": "Menfez'e sor: site adını yaz, engelli mi, hangi yolla açılıyor söylesin.",
            "hotkey_title": "Kısayol",
            "hotkey_none": "Yok",
            "hotkey_record": "Kaydet",
            "hotkey_recording": "Tuşlara bas…",
            "hotkey_clear": "Sil",
            "hotkey_note": "Doğrudan ile son kullandığın mod arasında geçer. Hiçbir izin istemez. Esc vazgeçer.",
            "hotkey_needs_modifier": "⌘, ⌥ ya da ⌃ ile birlikte bas.",
            "hotkey_taken": "Bu kısayol başka bir uygulamada kullanılıyor. Başka bir tane dene.",
            "hotkey_menu": "Kısayol: {what}",
            "ks_toggle": "Tünel düşerse interneti kes",
            "ks_hint_all": "Tünel düşerse hiçbir şey tünel dışından çıkmaz. Ev ağın (yazıcı, AirPlay) açık kalır.",
            "ks_hint_discord": "Tünel düşerse Discord kesilir, diğer siteler normal açılır.",
            "ks_blocked": "Tünel düştü, internet kapalı.",
            "ks_blocked_discord": "Tünel düştü, Discord kapalı.",
            "ks_blocked_sites": "Tünel düştü, Discord ve siteler kapalı.",
            "ks_hint_sites": "Tünel düşerse Discord ve listendeki siteler kesilir, gerisi normal açılır.",
            "m_sites": "Discord + siteler",
            "scope_sites_hint": "Discord ve listendeki siteler tünelden, gerisi normal internetten.",
            "sites_needs_update": "Seçili siteler için tünel bileşenini güncelle.",
            "sites_edit": "Siteler ({what})",
            "sites_title": "Tünelden geçen siteler",
            "sites_intro": "Bu siteler Discord'la birlikte tünelden gider, adları da tünelden çözülür. www. kendiliğinden eklenir; başka alt alan adlarını ayrı ekle.",
            "sites_placeholder": "ornek.com",
            "sites_add": "Ekle",
            "sites_remove": "Kaldır",
            "sites_empty": "Henüz site yok. Bir site adı yaz ve Ekle'ye bas.",
            "sites_invalid": "Bu bir site adı değil.",
            "sites_full": "Liste dolu (en çok {what} site).",
            "sites_save_failed": "Site listesi kaydedilemedi.",
            "sites_recovered": "Site listesi okunamadı; boş başlandı, eskisi sites.json.bak olarak duruyor.",
            "sites_updated": "Site adresleri güncellendi.",
            "sites_count": "{what} adres",
            "sites_unresolved": "Bu ad çözülemedi",
            "sites_checking": "Bakılıyor…",
            "sites_ago_now": "Güncellendi: az önce",
            "sites_ago_min": "Güncellendi: {what} dk önce",
            "sites_dns_outside": "Mac'in DNS'i ev ağında (modem), o yüzden site adları tünelden çözülemiyor. DNS ayarından herkese açık bir DNS seç.",
            "sites_not_active": "Kapsam Discord + siteler olunca bu siteler tünelden gider.",
            "ks_reconnect": "Yeniden bağlan",
            "ks_unblock": "Engeli kaldır",
            "ks_on_done": "Tünel düşerse internet kesilecek",
            "ks_off_done": "Engel kalktı",
            "ks_failed": "İnternet kesme açılamadı: {what}",
            "ks_waits": "Tünel açılınca devreye girer.",
            "help_ks_title": "İnternet kesildi ve geri gelmiyorsa",
            "help_ks": "Menfez'de Engeli kaldır'a bas ya da Doğrudan'a geç. Menfez'i kapatmak ve bilgisayarı yeniden başlatmak da engeli kaldırır. Menfez açılmıyorsa Terminal'e şunu yaz:",
            "leak_open": "Sızıntı testi",
            "leak_title": "Sızıntı testi",
            "leak_intro": "Trafiğin gerçekten tünelden mi gidiyor, bakıyorum. Sonuç saklanmaz.",
            "leak_running": "Bakılıyor…",
            "leak_again": "Yeniden test et",
            "leak_webrtc": "Tarayıcılar WebRTC ile yerel adresini sitelere gösterebilir. Bunu Menfez kapatamaz.",
            "leak_row_ip": "IP adresi",
            "leak_row_dns": "DNS",
            "leak_row_ipv6": "IPv6",
            "leak_row_killSwitch": "İnternet kesme",
            "leak_off": "Tünel açık değil, test edilecek bir şey yok.",
            "leak_ip_server": "Sunucunun adresi görünüyor",
            "leak_ip_exit": "Tünelin çıkış adresi görünüyor",
            "leak_ip_tunnel": "Trafik tünelden gidiyor",
            "leak_ip_leak": "Trafik tünel dışından gidiyor",
            "leak_ip_discord": "Discord tünelden gidiyor. Diğer siteler gerçek IP'ni görür.",
            "leak_ip_discord_leak": "Discord tünel dışından gidiyor",
            "leak_dns_tunnel": "Tünelden gidiyor",
            "leak_dns_leak": "Tünel dışından gidiyor. Sağlayıcın baktığın adları görebilir.",
            "leak_dns_discord": "Tünel dışından gidiyor. Sadece Discord'da bu olağan; sağlayıcın Discord'a baktığını görebilir.",
            "leak_dns_local": "Bu Mac'teki bir çözücü kullanılıyor, nereye gittiğini göremiyorum.",
            "leak_dns_unknown": "Çözücü bulunamadı",
            "leak_v6_none": "Bu ağda IPv6 yok, sızamaz",
            "leak_v6_tunnel": "Tünelden gidiyor",
            "leak_v6_blocked": "Engelli, sızmıyor",
            "leak_v6_leak": "Tünel dışından gidiyor",
            "leak_v6_discord": "Doğrudan gidiyor. Discord IPv6 kullanırsa tünel dışından gider.",
            "leak_ks_on": "Açık",
            "leak_ks_off": "Kapalı. Tünel düşerse trafik doğrudan gider.",
            "leak_ks_unknown": "Bilinmiyor: önce tünel yardımcısını güncelle.",
            "onb1_title": "Menfez ne yapar?",
            "onb1_1": "İnternet sağlayıcın bağlantıların içine bakıp bazılarını kesebiliyor. Buna DPI deniyor; Discord'un açılmamasının sebebi bu.",
            "onb1_2": "Menfez, Discord'un bağlantısını bu kontrole takılmayacak şekilde gönderir. Hesap, sunucu ya da ücret gerekmez; her şey bu Mac'te olur.",
            "onb1_3": "Kullanmak için Discord'u kapat, sonra Menfez'de Discord'u aç düğmesine bas.",
            "onb2_title": "Kendi sunucun varsa",
            "onb2_1": "DPI yetmezse ya da bütün internetini başka bir yerden geçirmek istersen tünel kullanabilirsin.",
            "onb2_2": "Menfez sunucu vermez. Bir WireGuard sağlayıcısından aldığın .conf dosyasını eklersin; tünel bir kez kurulur.",
            "onb2_3": "Sunucun yoksa bu adımı geç. DPI tek başına çalışır.",
            "onb3_title": "Hazırsın",
            "onb3_1": "Bir site açılmazsa Yardım'daki \"Bir siteyi test et\" ile engelli mi, hangi yolla açılıyor bak.",
            "onb3_2": "Tünel düşerse ya da DPI durursa sana bildirim gönderirim. macOS bunun için bir kez izin soracak. Bu rehber Yardım'da durur.",
            "onb3_3": "Discord kapalıysa Discord'u aç'a bas; Menfez önce DPI'ı açar, sonra Discord'u.",
            "onb_skip": "Geç",
            "onb_back": "Geri",
            "onb_next": "İleri",
            "onb_done": "Bitti",
            "onb_step": "Adım {n} / {of}",
            "onb_again": "Rehberi yeniden göster",
        ],
        .en: [
            "app": "Menfez",
            "tagline": "Discord on blocked networks",
            "m_discord": "Discord only",
            "m_all": "Whole internet",
            "scope_label": "Through the tunnel",
            "helper_outdated": "The tunnel component is older than this app. Update it to get the new features.",
            "helper_update": "Update",
            "scope_discord_hint": "Other apps use your normal internet.",
            "scope_all_hint": "Safari and every app go out with the server's IP.",
            "m_dpi": "DPI",
            "m_off": "Off",
            "m_updates": "Discord updates",
            "updates_tunnel": "Download Discord updates through the tunnel",
            "updates_tunnel_note": "In DPI mode only Discord updates and DNS go through the tunnel. Everything else stays on DPI.",
            "updates_tunnel_on": "Discord updates come through your tunnel",
            "updates_tunnel_failed": "Couldn't open the tunnel for updates. Discord may stay on \"Checking for updates\".",
            "mode_direct": "Direct",
            "mode_dpi": "DPI",
            "mode_tunnel": "Tunnel",
            "mode_direct_hint": "Menfez stays out of the way. Your connection is untouched.",
            "mode_dpi_hint": "Opens Discord through Menfez. No admin password needed.",
            "mode_tunnel_hint": "Sends your traffic through your own WireGuard server. Needs a one-time setup.",
            "dpi_enable_discord": "Open Discord",
            "dpi_enable_hint": "Menfez starts its proxy, then opens Discord",
            "dpi_enable_from_tunnel_hint": "Closes the tunnel, switches to DPI and opens Discord",
            "dpi_launch_again": "Reopen Discord",
            "dpi_launch_again_hint": "DPI is on. Discord quits and opens again.",
            "dpi_no_root_note": "No admin password needed. The proxy runs inside Menfez.",
            "tunnel_ready": "The tunnel is ready to use.",
            "tunnel_ready_pick": "Tunnel ready, pick a server.",
            "tunnel_ready_add": "Tunnel ready, add a server.",
            "direct_tunnel_present": "WireGuard tunnel up, DPI off",
            "tunnel_setup": "Set up",
            "tunnel_install": "Set up tunnel",
            "tunnel_remove": "Remove tunnel",
            "tunnel_installed": "Installed",
            "menu_settings": "Settings…",
            "tunnel_install_running": "Setting up. macOS will ask for your administrator password.",
            "tunnel_remove_running": "Removing. macOS will ask for your administrator password.",
            "tunnel_install_done": "Tunnel set up. You can pick Tunnel mode now.",
            "tunnel_remove_done": "Tunnel removed. DPI keeps working.",
            "tunnel_install_cancelled": "Cancelled. Nothing changed.",
            "tunnel_install_failed": "Setup didn't finish: {detail}",
            "tunnel_remove_failed": "Removal didn't finish: {detail}",
            "tunnel_remove_leave_first": "Leave Tunnel mode before removing it.",
            "help_setup_terminal": "If you prefer Terminal:",
            "tunnel_install_need_wg": "The WireGuard tools are needed first. In Terminal, run: brew install wireguard-tools wireguard-go bash",
            "tunnel_needs_setup": "To use the tunnel you need to set it up once.",
            "help_copy_command": "Copy command",
            "dpi_title": "DPI",
            "dpi_off": "off",
            "dpi_off_state": "DPI is off. Your connection goes direct.",
            "dpi_split": "split",
            "dpi_passthrough": "untouched",
            "dpi_open": "open",
            "dpi_refused": "refused",
            "dpi_at": "splits the first packet at byte {n}",
            "dpi_probe": "Test now",
            "dpi_probing": "testing…",
            "dpi_stop": "Stop",
            "dpi_quit_first": "If Discord is open, quit it first. Menfez can only set it up when Discord starts.",
            "discord_launch": "Open Discord through Menfez",
            "discord_launched": "Discord opened (proxy 127.0.0.1:{port})",
            "discord_settings_denied": "I couldn't write to Discord's settings file. Discord may stay on \"Checking for updates\". Allow it if macOS asks, then quit and reopen Discord.",
            "discord_settings_hint": "macOS stopped Menfez from writing to Discord's settings file, so Discord may wait on \"Checking for updates\". Menfez won't try again on its own. Press Try again and allow it if macOS asks. If you add your own server, this permission isn't needed.",
            "discord_settings_retry": "Try again",
            "dpi_port_changed": "The proxy port changed. If Discord is open, quit it and open it again from Menfez.",
            "st_direct": "Menfez is off. Your connection goes direct.",
            "st_dpi_on": "DPI is on (127.0.0.1:{port})",
            "st_tunnel_on": "Tunnel is on",
            "tunnel_lost": "The tunnel dropped. Your traffic may be going out unencrypted.",
            "tunnel_lost_blocked": "The tunnel dropped. Blocking is on, nothing goes out.",
            "tunnel_helper_missing": "The tunnel needs a one-time setup. DPI works without it.",
            "tunnel_not_installed": "The tunnel helper isn't installed. Press Set up tunnel.",
            "app_update_check": "Check for Updates…",
            "app_update_auto": "Check for updates automatically",
            "helper_no_reply": "the helper did not answer",
            "launch_proxyNotRunning": "Turn on DPI first. The proxy isn't running.",
            "launch_invalidPort": "Port {port} can't be used",
            "launch_alreadyRunning": "Discord is already open. Quit it first; Menfez can only set it up at launch.",
            "launch_notInstalled": "Discord isn't in the Applications folder",
            "launch_openFailed": "Couldn't open Discord: {what}",
            "discord_restart_title": "Restart Discord?",
            "discord_restart_body": "Discord still uses the proxy you turned off. It won't connect until it restarts.",
            "discord_restart_yes": "Restart",
            "discord_restart_no": "Not now",
            "discord_restart_later": "Restart Discord so it can connect.",
            "discord_restarted": "Discord reopened without the proxy",
            "probe_working": "The direct connection is blocked and DPI gets through. DPI is working.",
            "probe_notNeeded": "The direct connection works. This network isn't blocking right now, so you don't need DPI.",
            "probe_notHelping": "Neither got through. DPI isn't enough on this network; try the tunnel.",
            "probe_dnsBlocked": "Neither got through and the address didn't resolve. DNS is blocked. Change DNS and try again.",
            "probe_proxyBroken": "The direct connection works but the proxy doesn't. The problem is in Menfez's proxy.",
            "probe_proxyOff": "The proxy is off, so there's nothing to compare.",
            "probe_needs_proxy": "Turn on DPI first. The test runs through the proxy.",
            "probing": "testing the network…",
            "f_egress": "Current IP",
            "f_where": "Location",
            "f_isp": "Provider",
            "f_server": "Server",
            "f_dns": "DNS",
            "f_mode": "Mode",
            "f_routes": "Routes",
            "f_handshake": "Last contact",
            "f_transfer": "Data",
            "f_gateway": "Gateway",
            "pill_server": "Server:",
            "srv_edit": "Edit",
            "srv_delete": "Delete",
            "srv_name": "Server name",
            "srv_save": "Save",
            "srv_cancel": "Cancel",
            "srv_replace": "Replace config…",
            "srv_delete_q": "Delete {name}?",
            "srv_delete_body": "This server's config file is moved to the Trash. If the tunnel is using it, the app switches to Direct first.",
            "srv_deleted": "Deleted: {name}",
            "srv_delete_failed": "Couldn't delete {name}",
            "tunnel_orphan_closed": "Tunnel closed because its server was removed",
            "srv_not_in_list": "not in your list",
            "srv_renamed": "Renamed to {name}",
            "srv_bad_name": "That name won't work. Use letters, digits, spaces, - or _ (up to 64).",
            "srv_name_taken": "A server with that name already exists.",
            "srv_replaced": "Config replaced: {name}",
            "kc_offer_title": "Move server keys to Keychain",
            "kc_offer_body": "Keys won't sit on disk as plain text.",
            "kc_move": "Move",
            "kc_not_now": "Not now",
            "kc_move_link": "Move keys to Keychain",
            "kc_restore": "Write keys back to files",
            "kc_in_keychain": "Key is in Keychain",
            "kc_moved": "Keys are in Keychain ({n})",
            "kc_move_failed": "Couldn't move {n} key(s); those files are unchanged.",
            "kc_restored": "Keys written back to files ({n})",
            "kc_restore_failed": "Couldn't write back {n} key(s); those files are unchanged.",
            "kc_failed": "Couldn't read Keychain; tunnel not started",
            "f_discord": "Discord",
            "up": "Tunnel is on",
            "down": "Tunnel is off. Your connection goes direct.",
            "off_state": "Menfez is off",
            "unhealthy": "The tunnel is on but not working right",
            "routes_lost": "Routes are gone and traffic isn't flowing",
            "checking": "checking…",
            "switching": "switching to {what}…",
            "mode_set": "Mode: {what}",
            "server_set": "Server: {what}",
            "dns_set": "DNS: {what}",
            "failed": "Didn't work: {what}",
            "reconnected_last": "Reconnected to your last server: {what}",
            "choose_server": "The tunnel setting was cleared on restart. Pick a server.",
            "no_profiles": "No server yet. Add your own WireGuard .conf file.",
            "now": "just now",
            "last_updated": "Last updated {time}",
            "unused": "not in use",
            "none": "none",
            "auto": "Automatic",
            "never": "never",
            "active_n": "{n}/{total} active",
            "ok_ms": "reachable, {ms} ms",
            "ok": "reachable",
            "blocked": "blocked",
            "dns_blocked": "DNS blocked",
            "conn_failed": "can't connect",
            "proxy_failed": "proxy can't reach it",
            "tls_blocked": "TLS blocked",
            "http": "HTTP {code}",
            "refresh": "Refresh",
            "servers": "Choose a server",
            "dns_title": "Choose DNS",
            "close": "Close",
            "working": "loading…",
            "testing": "measuring DNS speed…",
            "automatic": "Automatic",
            "dns_note": "Times measured just now",
            "doh_title": "DNS Menfez uses",
            "doh_note": "Asked over encryption (DoH)",
            "dns_tunnel": "Send DNS through the tunnel",
            "dns_tunnel_note": "In Discord-only mode your DNS queries go through the tunnel too. Your router's DNS is left out.",
            "dns_tunnel_private": "Your DNS is on your router right now (e.g. 192.168.1.1), so it doesn't go through the tunnel. Pick a DNS such as 1.1.1.1 above.",
            "dns_routes_updated": "Network changed, DNS routes refreshed",
            "fastest": "fastest",
            "unreachable": "no answer",
            "s": "{n} s ago",
            "m": "{n} min ago",
            "h": "{n} h ago",
            "import_conf": "Add server…",
            "import_prompt": "Choose your WireGuard .conf file",
            "any_provider": "A .conf file from any WireGuard provider works. Menfez copies it into its own folder, and only your account can read it.",
            "import_ok": "Added: {what}",
            "byo_conf_short": "Add your own WireGuard .conf",
            "byo_conf": "The tunnel needs your own WireGuard file (.conf). Menfez doesn't come with a server.",
            "menu_open": "Open window",
            "menu_quit": "Quit",
            "launch_at_login": "Open at login",
            "launch_at_login_failed": "Couldn't set open at login: {what}",
            "login_move_first": "Move Menfez to the Applications folder first.",
            "login_needs_approval": "Allow Menfez in System Settings > General > Login Items.",
            "det_ip": "IP details",
            "det_routes": "Routes",
            "det_dns": "DNS",
            "det_tunnel": "Tunnel",
            "det_discord": "Discord",
            "copied": "copied",
            "help_hint": "Help",
            "about_hint": "About",
            "whatsnew_hint": "What's new",
            "whatsnew_version": "Version {v}",
            "whatsnew_current": "Current",
            "appearance": "Appearance",
            "app_system": "System",
            "app_dark": "Dark",
            "app_light": "Light",
            "about_version": "version {v}",
            "donate_hint": "Buy me a tea (burhanrb.com)",
            "export_log": "Save log…",
            "log_exported": "Debug log saved",
            "log_export_failed": "Couldn't save the debug log",
            "help_title": "Help",
            "help_modes": "There are three modes",
            "help_direct": "Direct: Menfez does nothing and your internet works as usual.",
            "help_dpi": "DPI: opens Discord past the block. No password or server needed.",
            "help_tunnel": "Tunnel: your internet traffic goes through your own server.",
            "help_which_title": "Which one should I use?",
            "help_which": "Try DPI mode first. If Discord still won't open, switch to the tunnel. If you don't need Discord, stay on Direct.",
            "help_conf_title": "Add your own server",
            "help_conf": "Menfez doesn't come with a server. Download a .conf file from your WireGuard provider's panel and add it here.",
            "help_discord_title": "If Discord won't open",
            "help_discord": "Quit Discord with Cmd+Q and open it again with the button in Menfez. If that fails, set DNS to 1.1.1.1. If it still fails, try the tunnel.",
            "help_discord_wait": "Discord may wait about 10 seconds and then open with the version you have. Updates arrive when you're on a network that doesn't block, or once you add your own server.",
            "help_setup_title": "Tunnel setup (once)",
            "help_setup": "Only the tunnel needs this. First install the WireGuard tools in Terminal: brew install wireguard-tools wireguard-go bash. Then press Set up tunnel and macOS will ask for your administrator password. Press it again after you update Menfez.",
            "help_log": "If the problem stays, save the debug log and attach it when you report on GitHub. The log hides your IP and keys.",
            "about_author": "Made by",
            "about_web": "Website",
            "about_support": "Support",
            "about_license": "Open source, Apache-2.0 license.",
            "about_licenses": "Third-party licenses",
            "dt_IP": "IP",
            "dt_Reverse DNS": "Reverse DNS",
            "dt_City": "City",
            "dt_Region": "Region",
            "dt_Country": "Country",
            "dt_Postal": "Postal code",
            "dt_Timezone": "Time zone",
            "dt_Coordinates": "Coordinates",
            "dt_Network": "Network",
            "dt_Provider": "Provider",
            "dt_Routing": "Route",
            "dt_Resolver": "DNS server",
            "dt_Interface": "Interface",
            "dt_Mode": "Mode",
            "dt_Endpoint": "Server address",
            "dt_Handshake": "Last contact",
            "dt_Received": "Received",
            "dt_Sent": "Sent",
            "dt_active": "present",
            "dt_missing": "missing",
            "dt_MISSING": "MISSING",
            "dt_no answer": "no answer",
            "dt_never": "never",
            "dt_unreachable": "unreachable",
            "dt_automatic (from DHCP)": "automatic (from router)",
            "dt_on-link, no gateway": "on the local network, no gateway",
            "dt_pinned via": "pinned via {what}",
            "dt_via": "{iface} via {gateway}",
            "dt_host": "host {what}",
            "dt_unreachable_why": "unreachable ({what})",
            "notify_title": "Notifications",
            "notify_tunnelDropped_setting": "Tunnel drops or comes back",
            "notify_serverRemoved_setting": "Removed server closes the tunnel",
            "notify_dpiStopped_setting": "DPI stops on its own",
            "notify_helperUpdate_setting": "Helper needs an update",
            "notify_note": "No notifications while the Menfez window is in front. The same alert comes at most once every 5 minutes.",
            "notify_tunnelDropped_title": "Tunnel dropped",
            "notify_tunnelDropped_body": "Your traffic is not going through the tunnel right now. Open Menfez to check.",
            "notify_tunnelRestored_title": "Tunnel is back",
            "notify_tunnelRestored_body": "Your traffic is going through the tunnel again.",
            "notify_serverRemoved_title": "Tunnel closed",
            "notify_serverRemoved_body": "The server you were using was removed from the list, so I closed the tunnel.",
            "notify_dpiStopped_title": "DPI stopped",
            "notify_dpiStopped_body": "DPI stopped unexpectedly. Discord may not connect. Turn it back on in Menfez.",
            "notify_helperUpdate_title": "Tunnel helper is out of date",
            "notify_helperUpdate_body": "Update the helper so the tunnel keeps working. Press Update in Menfez.",
            "sitetest_open": "Test a site…",
            "sitetest_title": "Test a site",
            "sitetest_intro": "Type a site name or address. Menfez tries it directly and with DPI at the same time and tells you in a few seconds. With the Whole internet tunnel on, it tries the tunnel.",
            "sitetest_placeholder": "example.com",
            "sitetest_run": "Test",
            "sitetest_running": "Trying",
            "sitetest_err_empty": "Type a site name first.",
            "sitetest_err_notAName": "That doesn't look like a site name. Try something like example.com",
            "sitetest_err_address": "Type a site name, not an IP address (e.g. example.com).",
            "sitetest_err_local": "That name is on your home network or this computer. Only sites on the internet can be tested.",
            "sitetest_err_port": "Only normal web addresses can be tested. Remove the :port part.",
            "sitetest_path_direct": "Directly",
            "sitetest_path_dpi": "With DPI",
            "sitetest_path_tunnel": "Through tunnel",
            "sitetest_opens": "Opens",
            "sitetest_fails": "Doesn't open",
            "sitetest_timedOut": "No answer",
            "sitetest_notFound": "Name not found",
            "sitetest_sum_opensDirect": "This site isn't blocked; it opens directly.",
            "sitetest_sum_opensWithDPI": "This site is blocked, but it opens with DPI. For now Menfez uses DPI only for Discord; to open it in your browser, use the Whole internet tunnel.",
            "sitetest_sum_opensWithTunnel": "This site opens through the tunnel.",
            "sitetest_sum_opensNowhere": "This site doesn't open directly or with DPI. It may be down, or the block is stricter. If you have your own server, try the Whole internet tunnel.",
            "sitetest_sum_opensNowhereTunnel": "This site doesn't open through the tunnel either. It may be down right now.",
            "sitetest_sum_notFound": "This name wasn't found. Check the spelling.",
            "sitetest_sum_refused": "This name points to an address on your home network, so I didn't test it.",
            "sitetest_tunnel_discord_only": "The tunnel only carries Discord right now, so the site wasn't tried through it.",
            "help_sitetest_title": "If a site won't open",
            "help_sitetest": "Ask Menfez: type the site name and it tells you whether it's blocked and which way it opens.",
            "hotkey_title": "Shortcut",
            "hotkey_none": "None",
            "hotkey_record": "Record",
            "hotkey_recording": "Press keys…",
            "hotkey_clear": "Clear",
            "hotkey_note": "Switches between Direct and the mode you used last. Needs no permission. Esc cancels.",
            "hotkey_needs_modifier": "Press it together with ⌘, ⌥ or ⌃.",
            "hotkey_taken": "Another app already uses this shortcut. Try a different one.",
            "hotkey_menu": "Shortcut: {what}",
            "ks_toggle": "Block internet if the tunnel drops",
            "ks_hint_all": "If the tunnel drops, nothing leaves outside it. Your home network (printer, AirPlay) still works.",
            "ks_hint_discord": "If the tunnel drops, Discord is cut. Other sites open as usual.",
            "ks_blocked": "Tunnel dropped, internet blocked.",
            "ks_blocked_discord": "Tunnel dropped, Discord blocked.",
            "ks_blocked_sites": "Tunnel dropped, Discord and your sites blocked.",
            "ks_hint_sites": "If the tunnel drops, Discord and the sites on your list are cut. The rest opens as usual.",
            "m_sites": "Discord + sites",
            "scope_sites_hint": "Discord and the sites on your list go through the tunnel; the rest uses your normal internet.",
            "sites_needs_update": "Update the tunnel component to use chosen sites.",
            "sites_edit": "Sites ({what})",
            "sites_title": "Sites through the tunnel",
            "sites_intro": "These sites go through the tunnel with Discord, and their names are looked up through it too. www. is added for you; add other subdomains separately.",
            "sites_placeholder": "example.com",
            "sites_add": "Add",
            "sites_remove": "Remove",
            "sites_empty": "No sites yet. Type a site name and press Add.",
            "sites_invalid": "That isn't a site name.",
            "sites_full": "The list is full (at most {what} sites).",
            "sites_save_failed": "Couldn't save the site list.",
            "sites_recovered": "Couldn't read the site list, so it starts empty; the old one is kept as sites.json.bak.",
            "sites_updated": "Site addresses updated.",
            "sites_count": "{what} addresses",
            "sites_unresolved": "Could not resolve this name",
            "sites_checking": "Looking up…",
            "sites_ago_now": "Updated: just now",
            "sites_ago_min": "Updated: {what} min ago",
            "sites_dns_outside": "Your Mac's DNS is on your home network (the router), so site names can't be looked up through the tunnel. Pick a public DNS in DNS settings.",
            "sites_not_active": "These sites go through the tunnel when the scope is Discord + sites.",
            "ks_reconnect": "Reconnect",
            "ks_unblock": "Unblock",
            "ks_on_done": "Internet will be blocked if the tunnel drops",
            "ks_off_done": "Unblocked",
            "ks_failed": "Couldn't turn on blocking: {what}",
            "ks_waits": "It kicks in when the tunnel is on.",
            "help_ks_title": "If the internet is blocked and won't come back",
            "help_ks": "Press Unblock in Menfez, or switch to Direct. Quitting Menfez or restarting the Mac also lifts it. If Menfez won't open, type this in Terminal:",
            "leak_open": "Leak test",
            "leak_title": "Leak test",
            "leak_intro": "Checking that your traffic really goes through the tunnel. Nothing is saved.",
            "leak_running": "Checking…",
            "leak_again": "Test again",
            "leak_webrtc": "Browsers can show your local address to sites through WebRTC. Menfez can't turn that off.",
            "leak_row_ip": "IP address",
            "leak_row_dns": "DNS",
            "leak_row_ipv6": "IPv6",
            "leak_row_killSwitch": "Blocking",
            "leak_off": "The tunnel isn't on, so there's nothing to test.",
            "leak_ip_server": "Sites see the server's address",
            "leak_ip_exit": "Sites see the tunnel's exit address",
            "leak_ip_tunnel": "Traffic goes through the tunnel",
            "leak_ip_leak": "Traffic goes outside the tunnel",
            "leak_ip_discord": "Discord goes through the tunnel. Other sites see your real IP.",
            "leak_ip_discord_leak": "Discord goes outside the tunnel",
            "leak_dns_tunnel": "Goes through the tunnel",
            "leak_dns_leak": "Goes outside the tunnel. Your provider can see the names you look up.",
            "leak_dns_discord": "Goes outside the tunnel. That's normal with Discord only; your provider can see you look up Discord.",
            "leak_dns_local": "A resolver on this Mac is in use; I can't see where it goes.",
            "leak_dns_unknown": "No resolver found",
            "leak_v6_none": "No IPv6 on this network, nothing to leak",
            "leak_v6_tunnel": "Goes through the tunnel",
            "leak_v6_blocked": "Blocked, doesn't leak",
            "leak_v6_leak": "Goes outside the tunnel",
            "leak_v6_discord": "Goes direct. If Discord uses IPv6, it skips the tunnel.",
            "leak_ks_on": "On",
            "leak_ks_off": "Off. If the tunnel drops, traffic goes direct.",
            "leak_ks_unknown": "Unknown: update the tunnel helper first.",
            "onb1_title": "What Menfez does",
            "onb1_1": "Your internet provider can look inside your connections and cut some of them. This is called DPI, and it's why Discord won't open.",
            "onb1_2": "Menfez sends Discord's connection in a way that slips past this check. No account, server or payment needed; it all happens on this Mac.",
            "onb1_3": "To use it, quit Discord, then press Open Discord in Menfez.",
            "onb2_title": "If you have your own server",
            "onb2_1": "If DPI isn't enough, or you want all your internet to go out somewhere else, you can use a tunnel.",
            "onb2_2": "Menfez doesn't come with a server. You add the .conf file you get from a WireGuard provider; the tunnel is set up once.",
            "onb2_3": "No server? Skip this step. DPI works on its own.",
            "onb3_title": "You're set",
            "onb3_1": "If a site won't open, use \"Test a site\" in Help to see whether it's blocked and which way it opens.",
            "onb3_2": "If the tunnel drops or DPI stops, I'll send you a notification. macOS will ask permission once. This guide stays in Help.",
            "onb3_3": "With Discord closed, press Open Discord; Menfez turns on DPI first, then opens Discord.",
            "onb_skip": "Skip",
            "onb_back": "Back",
            "onb_next": "Next",
            "onb_done": "Done",
            "onb_step": "Step {n} of {of}",
            "onb_again": "Show the guide again",
        ],
    ]

    func t(_ key: String, _ args: [String: String] = [:]) -> String {
        var s = L.table[lang]?[key] ?? key
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    /// The probe verdict in the UI language; the enum's own `sentence` is
    /// English and stays for logs and the CLI.
    func verdict(_ v: DPIProbeOutcome.Verdict) -> String { t("probe_" + v.rawValue) }

    /// A detail-popup label or value in the UI language. The helper sends fixed
    /// English words (its JSON is shared with the CLI); anything not in the
    /// table, such as an address or a city name, passes through unchanged.
    func detail(_ s: String) -> String {
        if let hit = L.table[lang]?["dt_" + s] { return hit }
        if s.hasSuffix(" s ago"), let n = Int(s.dropLast(6)) { return t("s", ["n": "\(n)"]) }
        if s.hasPrefix("pinned via ") { return t("dt_pinned via", ["what": String(s.dropFirst(11))]) }
        if s.hasPrefix("host ") { return t("dt_host", ["what": String(s.dropFirst(5))]) }
        if s.hasPrefix("unreachable ("), s.hasSuffix(")") {
            return t("dt_unreachable_why", ["what": String(s.dropFirst(13).dropLast())])
        }
        // "en0 via 192.168.1.1" from `Probes.routeSummary`.
        if let r = s.range(of: " via "), s.split(separator: " ").count == 3 {
            return t("dt_via", ["iface": String(s[..<r.lowerBound]), "gateway": String(s[r.upperBound...])])
        }
        return s
    }

    /// A Discord launch refusal in the UI language.
    func launchError(_ e: DiscordLauncher.LaunchError) -> String {
        switch e {
        case .proxyNotRunning:     return t("launch_proxyNotRunning")
        case .invalidPort(let p):  return t("launch_invalidPort", ["port": "\(p)"])
        case .alreadyRunning:      return t("launch_alreadyRunning")
        case .notInstalled:        return t("launch_notInstalled")
        case .openFailed(let why): return t("launch_openFailed", ["what": why])
        }
    }

    /// A mode switch's outcome in the UI language.
    ///
    /// Built from the state's enum fields, not from its English `message`:
    /// a success is a fixed localised sentence (plus the helper's own note,
    /// which can say the safety net is not armed); a failure keeps the
    /// technical text behind a localised "Failed:" label.
    func modeState(_ state: ModeState, hasProfiles: Bool) -> String {
        guard state.ok else {
            let what = state.recovery == .chooseServer
                ? t(TunnelRecovery.chooseServerMessageKey(hasProfiles: hasProfiles))
                : state.message == NoTunnel.message ? t("tunnel_not_installed")
                : state.message == ProfileKeys.readFailure ? t("kc_failed") : state.message
            return t("failed", ["what": what])
        }
        let head: String
        switch state.mode {
        case .direct: head = t("st_direct")
        case .dpi:    head = t("st_dpi_on", ["port": "\(state.proxy.port ?? 0)"])
        case .tunnel: head = t("st_tunnel_on")
        }
        var recovered: String?
        if case .reconnected(let name) = state.recovery {
            recovered = t("reconnected_last", ["what": name])
        }
        let updates = state.updatesViaTunnel.map { t($0 ? "updates_tunnel_on" : "updates_tunnel_failed") }
        return [head, recovered, state.helperNote, updates].compactMap { $0 }.joined(separator: " · ")
    }
}

extension Result {
    /// True when the value is present. Reads better than pattern-matching at a
    /// call site that only cares whether the retry worked.
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Country data

enum Countries {
    /// Thin facade over the core table. The data lives in `CountryNames` so a
    /// filename parsed in the core renders the same name here.
    static let flags: [String: String] = [
        "TR": "🇹🇷", "BG": "🇧🇬", "DE": "🇩🇪", "GR": "🇬🇷", "NL": "🇳🇱",
        "RO": "🇷🇴", "US": "🇺🇸", "GB": "🇬🇧", "FR": "🇫🇷", "CH": "🇨🇭",
        "SE": "🇸🇪", "JP": "🇯🇵", "SG": "🇸🇬", "PL": "🇵🇱", "CA": "🇨🇦",
        "AT": "🇦🇹", "IT": "🇮🇹", "ES": "🇪🇸", "NO": "🇳🇴", "FI": "🇫🇮",
        "DK": "🇩🇰", "BE": "🇧🇪", "CZ": "🇨🇿", "HU": "🇭🇺", "IE": "🇮🇪",
        "PT": "🇵🇹", "RU": "🇷🇺", "UA": "🇺🇦", "BR": "🇧🇷", "AR": "🇦🇷",
        "MX": "🇲🇽", "AU": "🇦🇺", "NZ": "🇳🇿", "KR": "🇰🇷", "IN": "🇮🇳",
        "ZA": "🇿🇦", "AE": "🇦🇪", "IL": "🇮🇱", "LT": "🇱🇹", "LV": "🇱🇻",
        "EE": "🇪🇪", "SK": "🇸🇰", "SI": "🇸🇮", "HR": "🇭🇷", "RS": "🇷🇸",
        "MD": "🇲🇩", "IS": "🇮🇸", "LU": "🇱🇺",
    ]

    static func name(_ code: String?, lang: Lang) -> String {
        CountryNames.name(code, turkish: lang == .tr) ?? ""
    }

    static func flag(_ code: String?) -> String {
        ProfileNaming.flag(code) ?? "🌐"
    }
}

// MARK: - Backend client

/// Runs the `menfez-route` helper and decodes its JSON.
///
/// Everything here is off the main thread; the UI polls a published state.
///
/// THE READ PATH
/// Two very different things used to share one method. `report` spawned a root
/// process for a full observation, and the UI called it every 5 seconds even
/// when nothing had changed and the window was in the background. Only four
/// numbers in that observation actually need root (`wg show <iface>` is
/// "Permission denied" as the user); everything else — routes, resolvers,
/// gateway, interfaces, the byte counters' *derived* ages — is readable by any
/// user. So the fast path is now `localReport()`, which spawns no privileged
/// process at all, and the privileged half is `facts()`, called on a much
/// slower schedule and merged in. See docs/READ-PATH.md.
// @unchecked: every stored property is set in init and never mutated after
// (`client` is lazy but forced in init); HelperClient is itself Sendable.
/// The two switches behind "keys in the Keychain" (1.0.7).
enum KeychainKeys {
    /// The user moved keys to the Keychain; new imports follow.
    static let onKey = "keychain.on"
    static let dismissedKey = "keychain.offerDismissed"

    /// After an import: once keys live in the Keychain, the new file's key
    /// goes there too. A failed move leaves the file as imported (it still
    /// works); the next "Move keys" picks it up.
    static func follow(_ result: Result<Profile, WireGuardProfiles.ImportError>)
        -> Result<Profile, WireGuardProfiles.ImportError> {
        guard case .success(var profile) = result,
              UserDefaults.standard.bool(forKey: onKey), KeychainStore.signedWithTeam
        else { return result }
        if ProfileKeys.moveToStore(file: profile.file, store: KeychainStore()) { profile.keychain = true }
        return .success(profile)
    }
}

final class Backend: @unchecked Sendable {
    /// Absolute path of the privileged helper: always the root-owned installed
    /// copy the sudoers rule names. A copy in the bundle or a build directory
    /// is writable by the user, so it is never run through sudo.
    let helper = TunnelSetup.trustedHelper

    /// The copy shipped in this bundle, which the one-time setup installs.
    /// Empty outside a bundle (a `swift run`), where Help shows no command.
    let bundledHelper: String

    init() {
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("menfez-route").path ?? ""
        bundledHelper = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : ""
        // K5: re-pin the tunnel endpoint after a network change or wake.
        let client = self.client
        networkWatcher = NetworkChangeWatcher(wakeCenter: NSWorkspace.shared.notificationCenter) {
            let result = client.act(["repin"], timeout: 60)
            guard !result.ok else { return }
            // The model owns the status line; it maps this through `failed`.
            NotificationCenter.default.post(name: Backend.repinFailed, object: nil,
                                            userInfo: ["error": result.error ?? "repin"])
        }
        networkWatcher?.start()
        // Any network change (not only with a tunnel up) can move the
        // primary service or its DHCP resolvers.
        let cache = dnsCache
        dnsWatcher = NetworkChangeWatcher(debounce: 0.5, isActive: { true }) {
            cache.invalidate()
            NotificationCenter.default.post(name: Backend.networkChanged, object: nil)
        }
        dnsWatcher?.start()
    }
    private var networkWatcher: NetworkChangeWatcher?
    private var dnsWatcher: NetworkChangeWatcher?
    /// Posted (off main) when a background `repin` fails; userInfo["error"].
    static let repinFailed = Notification.Name("MenfezRepinFailed")
    /// Posted (off main) after any debounced network path change.
    static let networkChanged = Notification.Name("MenfezNetworkChanged")

    // MARK: - Unprivileged reads

    /// Everything the UI can show without root, gathered in-process.
    ///
    /// This is a plain function call, not a subprocess: `RouteManager`,
    /// `DNSManager` and `Probes` are linked into the app. The only processes it
    /// starts are `route`, `networksetup`, `ifconfig`, `ipconfig` and `wg show
    /// interfaces`, all of which run as the user.
    func localReport(depth: ReportBuilder.Depth = .local) -> Report {
        ReportBuilder().buildLocal(depth: depth, dnsCache: dnsCache, using: localRunner())
    }

    /// The service name and resolvers between ticks; see `DNSInfoCache`.
    let dnsCache = DNSInfoCache()

    /// The three network-backed rows, with no local pass around them.
    /// The Discord popup's fresh rows, without the helper: on the same path as
    /// the card's Discord row (proxy and DoH in DPI mode), a few seconds at most.
    func discordDetail(proxyPort: Int?) -> [DetailItem] {
        Details.discordLive(proxyPort: proxyPort, using: localRunner())
    }

    func probes(discordProxyPort: Int?) -> ReportBuilder.ProbeResult {
        ReportBuilder.probes(discordProxyPort: discordProxyPort, using: localRunner())
    }

    /// The real runner, wrapped so the spawn counter sees local reads too.
    ///
    /// The fast path's budget is "a handful of unprivileged commands"; counting
    /// only the privileged ones would hide a regression that turned one `route
    /// -n get` back into three.
    private func localRunner() -> CommandRunner {
        let client = self.client
        return CountingRunner(base: SystemRunner()) { tool in
            client.recordLocal(tool)
        }
    }

    /// The profiles list, from disk only.
    ///
    /// `liveHost` is passed in by the caller when it has one from `facts()`;
    /// without it no row is marked active, which the picker renders as "none
    /// highlighted" rather than a wrong highlight.
    func profiles(liveHost: String?, livePeerKey: String? = nil) -> [Profile] {
        WireGuardProfiles.list(liveHost: liveHost,
                               livePeerKey: livePeerKey,
                               resolveLiveHost: false,
                               using: localRunner())
    }

    /// Countries for profile hosts whose config named none.
    ///
    /// Split from `profiles` so the list paints first: a provider file that
    /// already says "RO" costs nothing, a hand-written one costs one cached
    /// request (see GeoFromIP), and that request must never hold up the rows.
    func countries(for list: [Profile]) -> [String: String] {
        let unknown = list.filter { $0.country == nil }.compactMap(\.host)
        return unknown.isEmpty ? [:] : GeoFromIP.countries(forIPs: unknown)
    }

    /// Copy a chosen `.conf` into the profile folder. Local only: no helper,
    /// no sudo. The write is mode 0600 from the first byte.
    func importConfig(from path: String,
                      overwrite: Bool) -> Result<Profile, WireGuardProfiles.ImportError> {
        KeychainKeys.follow(WireGuardProfiles.importConfig(from: path, overwrite: overwrite))
    }

    /// The DNS sheet's data. Costs a burst of `dig` (three per preset), so it
    /// belongs to a user action, not to the refresh timer.
    func dns() -> DNSReport? {
        DNSManager().report(using: localRunner())
    }

    // MARK: - Privileged reads

    /// The privileged client, with its spawn counter.
    ///
    /// All the fallback and counting logic lives in `MenfezCore.HelperClient`
    /// so a test can drive it; this just holds one instance.
    /// Shared by the report path and the tunnel coordinator so both see
    /// one set of counters and one spawn budget.
    fileprivate lazy var client = HelperClient(helper: helper)

    /// What has been spawned since launch, by tool.
    var spawns: [String: Int] { client.spawns }
    var hasSpawnedRoot: Bool { client.spawnedRoot }
    func resetSpawns() { client.resetSpawns() }

    private func run(_ args: [String], timeout: TimeInterval = 120) -> CommandResult {
        client.run(args, timeout: timeout)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ args: [String],
                                      timeout: TimeInterval = 120) -> T? {
        let result = run(args, timeout: timeout)
        guard result.ok else { return nil }
        return JSON.decode(type, from: result.output)
    }

    /// The privileged half of the report: four `wg` reads, one round trip.
    ///
    /// Returns nil when the helper could not run, which the caller must treat
    /// as "the privileged fields are unknown", never as "the tunnel is down".
    func facts() -> RouteManager.TunnelFacts? {
        client.facts()
    }

    /// A full report built by the helper, privileged fields included.
    ///
    /// Kept for the one-off cases where a whole fresh observation is wanted in
    /// a single call. The refresh loop does not use it: it would put a root
    /// process on the 5-second path again.
    func privilegedReport(full: Bool = false) -> Report? {
        client.report(full: full)
    }

    func detail(_ what: String, value: String? = nil) -> [DetailItem] {
        client.detail(what, value: value)?.items ?? []
    }

    @discardableResult
    func act(_ args: [String], timeout: TimeInterval = HelperClient.actTimeout) -> ActionResult? {
        client.act(args, timeout: timeout)
    }
}

/// A runner that reports each call before passing it on.
///
/// Used only by `Backend`, so the app's own spawn count is what gets measured —
/// not `ReportBuilder`'s idea of it.
private struct CountingRunner: CommandRunner {
    let base: CommandRunner
    let note: @Sendable (String) -> Void

    func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        note(tool)
        return base.run(tool, args, timeout: timeout)
    }
}

// MARK: - View model

@MainActor
final class Model: ObservableObject {
    @Published var report: Report? { didSet { reportAt = Date(); fillServerGeo() } }
    /// When `report` last changed, for the footer's "last updated" line.
    @Published var reportAt: Date?

    /// "Son güncelleme 14:05", or nothing before the first report.
    var lastUpdatedLine: String {
        guard let reportAt else { return "" }
        return l.t("last_updated", ["time": reportAt.formatted(date: .omitted, time: .shortened)])
    }
    @Published var profiles: [Profile] = []
    @Published var dns: DNSReport?
    @Published var busy = false
    /// A Discord still pointed at the proxy we just closed; non-nil shows the
    /// restart question. Set only from the post-switch task, never a body.
    @Published var discordRestartPID: Int32?
    /// macOS refused Discord's settings.json; see `DiscordLauncher.FailOpenMemory`.
    @Published var discordSettingsHint = DiscordLauncher.FailOpenMemory().showsHint
    @Published var status = ""
    @Published var statusColor = Palette.secondary
    /// Bumped when a tunnel start needs a server; the view opens the servers
    /// sheet on change. A counter, not a flag, so a second ask still fires.
    @Published var serverRequests = 0
    /// Bumped by the DPI menu's "Test a site…"; the window opens the sheet.
    @Published var siteTestRequests = 0

    /// Tunnel mode carries everything, so a site test can only try the tunnel.
    var tunnelCarriesEverything: Bool {
        runMode == .tunnel && tunnelCarriesTraffic && tunnelScope == .all
    }

    /// One site test (`SiteTest`), off the main thread. DPI is tried through
    /// a proxy started for the test alone, so it works in every mode and the
    /// running proxy's counters stay Discord's.
    func runSiteTest(_ host: String) async -> SiteTest.Report {
        let paths = SiteTest.paths(tunnelCarriesEverything: tunnelCarriesEverything)
        return await Task.detached(priority: .userInitiated) {
            var engine: DPIEngine?
            var port: Int?
            if paths.contains(.dpi) {
                var config = DPIEngine.Configuration()
                let split = UserDefaults.standard.integer(forKey: DPIEngine.splitDefaultsKey)
                if DPIEngine.splitRange.contains(split) { config.firstRecordPayloadLimit = split }
                let e = DPIEngine(configuration: config)
                port = (try? e.start())?.port
                engine = e
            }
            defer { engine?.stop() }
            return SiteTest.run(host: host, paths: paths, proxyPort: port)
        }.value
    }
    @Published var lang: Lang = .tr

    /// The DPI proxy's published status. Refreshed from the engine on the fast
    /// tick (a lock and a few integers, no I/O) so the counters in the card are
    /// live without a second source of truth.
    @Published var dpi = DPIStatus()

    /// What this machine can actually do, probed once at launch.
    ///
    /// The default is the rootless shape, deliberately: the window paints with
    /// "DPI only" before any probe has run, so a slow or hung `sudo -n` cannot
    /// delay the first frame with a spinner or, worse, with an error. If the
    /// probe later finds a working helper, the tunnel row lights up.
    @Published var capabilities = Capabilities.dpiOnly()

    /// The tunnel-unavailable sentence in the current language.
    ///
    /// `Capabilities` lives in the core and cannot see the UI language, so it
    /// carries both strings and this picks one. Reading `reason` directly
    /// shipped English text into a Turkish window.
    var tunnelReason: String {
        guard let reason = capabilities.reason,
              reason != TunnelSetup.missingHelperReason else {
            return l.t("tunnel_helper_missing")
        }
        // The two known reasons have translations; anything else is a sudo
        // message we pass through untranslated because inventing a paraphrase
        // of a tool error would hide what actually happened.
        if reason == TunnelSetup.notPermittedReason {
            return TunnelSetup.notPermitted(turkish: lang == .tr)
        }
        if reason == TunnelSetup.timedOutReason {
            return TunnelSetup.timedOut(turkish: lang == .tr)
        }
        return reason
    }

    /// The last probe result, or nil before the user has asked for one.
    @Published var probe: DPIProbeOutcome?
    @Published var probing = false

    /// The one owner of "which interception is live".
    ///
    /// It replaced a bare `DPIMode` plus an ad-hoc `dpiOn` boolean. The boolean
    /// was the bug: it recorded what the user clicked, not what the machine was
    /// doing, so a refused bind or a failed teardown could leave the panel
    /// claiming DPI mode while nothing was listening.
    lazy var coordinator: ModeCoordinator = makeCoordinator()

    /// The proxy half, for the views that only need Discord and the counters.
    ///
    /// Typed as `DPIMode` rather than the protocol because the Discord helpers
    /// (`launchDiscord`, `discordAvailability`) are not part of the seam: they
    /// are real app behaviour that the tests drive directly.
    var dpiMode: DPIMode? { coordinator.dpi as? DPIMode }

    /// What is actually running. `direct` means nothing intercepts.
    ///
    /// Read from the coordinator rather than stored, so there is exactly one
    /// place that knows the answer and no second flag to drift out of sync.
    var runMode: RunMode { coordinator.mode }

    /// True when the DPI proxy is the live interception. Kept as a name because
    /// a dozen view expressions read better with it than with `runMode == .dpi`.
    var dpiOn: Bool { coordinator.mode == .dpi }

    private func makeCoordinator() -> ModeCoordinator {
        // The helper is only wired in when it exists. Without one, `NoTunnel`
        // refuses with a sentence instead of spawning sudo on every click — the
        // whole point of the rootless default.
        // Re-checked on every call, so installing or removing the helper
        // takes effect without a relaunch (`InstalledTunnel`).
        let helper = backend.helper
        let tunnel = InstalledTunnel(
            installed: { FileManager.default.isExecutableFile(atPath: helper) },
            helper: HelperTunnel(client: backend.client,
                           lastProfile: { UserDefaults.standard.string(forKey: Model.lastProfileKey) },
                           dnsRouteArgs: { Model.dnsRouteArgs() }))
        tunnelControl = tunnel
        return ModeCoordinator(
            dpi: DPIMode(engine: DPIEngine(portStore: .standard),
                         discordRunning: { DiscordPresence.isRunning }),
            tunnel: tunnel)
    }

    /// DPI mode's updater routes, or nil when the setting is off or there is
    /// no profile. Blocking: DoH lookups and `scutil --dns`.
    nonisolated static func updateRoutes() -> UpdateRoutes? {
        guard DiscordUpdateRoutes.isEnabled(),
              !WireGuardProfiles.list(liveHost: nil).isEmpty else { return nil }
        return DiscordUpdateRoutes.plan(systemResolvers: DNSManager.systemResolvers())
    }

    /// The "updates through the tunnel" setting changed: apply it now.
    func updatesSettingChanged() {
        guard dpiOn, !busy else { return }
        busy = true
        Task {
            let result = await coordinator.syncUpdateTunnel()
            self.busy = false
            if let result {
                status = l.t(result ? "updates_tunnel_on" : "updates_tunnel_failed")
                statusColor = result ? Palette.success : Palette.warning
            }
            self.refresh(announce: false)
        }
    }

    /// `--dns-routes` for the helper: the system's public resolvers, when the
    /// "route DNS through tunnel" setting is on. Plus `--tunnel-dns`, which the
    /// helper uses only in Whole internet: `profile`'s own `DNS =` line (the
    /// last-used profile by default), else the public resolver picked in the
    /// DNS sheet.
    nonisolated static func dnsRouteArgs(profile: String? = nil) -> [String] {
        let list = WireGuardProfiles.list(liveHost: nil)
        let name = profile ?? TunnelRecovery.selection(
            lastProfile: UserDefaults.standard.string(forKey: lastProfileKey), available: list.map(\.name))
        let own = name.flatMap { n in list.first { $0.name == n }?.dns }
        let servers = TunnelScope.tunnelDNS(profileDNS: own, fallback: DoHProvider.current().addresses)
        return RouteManager.dnsRouteArgs(enabled: dnsThroughTunnel(),
                                         resolvers: DNSManager.systemResolvers())
            + ["--tunnel-dns", servers.joined(separator: ",")]
            + siteRouteArgs()
    }

    /// The DNS-through-tunnel toggle, or Discord + chosen sites, which always
    /// routes the public resolvers in: a blocked site's name answered by the
    /// ISP's resolver would point the browser somewhere else entirely.
    nonisolated static func dnsThroughTunnel() -> Bool {
        DNSManager.routesDNSThroughTunnel() || TunnelScope.choice() == .sites
    }

    /// `--site-routes` when Discord + chosen sites is the saved choice: the
    /// last lookup (`SiteAddressCache`). Off the main thread with no lookup
    /// yet (a tunnel start right after launch), it looks the sites up first;
    /// on the main thread it never waits for the network.
    nonisolated static func siteRouteArgs() -> [String] {
        guard TunnelScope.choice() == .sites else { return [] }
        if SiteAddressCache.shared.addresses.isEmpty, !Thread.isMainThread {
            let sites = SiteList.load().list.sites
            if !sites.isEmpty { SiteAddressCache.shared.addresses = SiteRoutes.resolve(sites).addresses }
        }
        return SiteRoutes.argument(SiteAddressCache.shared.addresses)
    }

    /// UserDefaults key: the profile last seen carrying the tunnel.
    nonisolated static let lastProfileKey = "lastProfile"

    let backend = Backend()
    private var timer: Timer?
    /// Tokens from the block-based `addObserver` calls in `init`.
    private var observers: [NSObjectProtocol] = []
    private let prefsURL: URL

    /// The privileged read, cached between refreshes.
    ///
    /// WHY THIS IS CACHED AT ALL
    /// `wg show <iface>` is the only root-owned read in the whole report. Asking
    /// for it on every redraw was the bug. These four numbers change on the
    /// order of a keepalive (25 s), not of a repaint, so they are fetched on a
    /// slow tick and the fast tick only recomputes the *ages* derived from the
    /// epoch. Nothing is invented: before the first successful read every field
    /// is nil, and the UI draws a dash.
    private var facts: RouteManager.TunnelFacts?
    private var factsAt: Date?
    private var factsInFlight = false

    /// How often the privileged read is repeated while the window is active.
    ///
    /// 25 s is the keepalive interval in the Proton configs, so a faster read
    /// would mostly confirm the same number. Anything slower than ~60 s makes
    /// the handshake row visibly stale next to a transfer counter that is only
    /// as fresh as its own fetch.
    private let factsInterval: TimeInterval = 25

    /// True once the capability probe has been asked for.
    ///
    /// A separate flag from `capabilities` because the answer is a value: a
    /// machine with no helper and a machine that has not been asked both read
    /// `tunnelAvailable == false`, and only the flag can tell them apart.
    private var capabilitiesProbed = false

    /// Fast tick: two seconds while the window is frontmost.
    ///
    /// The old 5 s was chosen for a privileged call. This tick spawns no root
    /// process, so it can be quicker without costing anything: four local
    /// commands that finish in ~120 ms together.
    private let activeTick: TimeInterval = 2

    /// Slow tick: 15 s while the window exists but is not frontmost.
    ///
    /// A background window still has to tell the user "your tunnel broke", but
    /// nobody is reading a byte counter they cannot see, so the rate drops.
    private let idleTick: TimeInterval = 15

    /// True while the app is the frontmost application.
    private var isActive = true

    /// True while a mode change is settling. A mutation just rewrote the route
    /// table, so the next few seconds are exactly when the user is watching and
    /// exactly when the values move; the fast tick is kept for that window even
    /// if the window loses focus during it.
    private var settlingUntil: Date?

    /// How long after a mutation the fast tick is held: long enough for
    /// wg-quick and the route rewrite to show up in the next reads.
    private let settleWindow: TimeInterval = 8

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            .appendingPathComponent("Menfez", isDirectory: true)
        prefsURL = base.appendingPathComponent("ui.json")

        if let data = try? Data(contentsOf: prefsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["lang"] as? String, let l = Lang(rawValue: raw) {
            lang = l
        } else {
            lang = Locale.current.language.languageCode?.identifier == "tr" ? .tr : .en
        }

        status = L(lang: lang).t("checking")
        readLaunchAtLogin()

        // First paint waits for nothing: `report` stays nil (rows read
        // "checking") and the local pass — wg, ifconfig, route, ipconfig,
        // networksetup — runs off the main thread from the deferred block below.
        // The privileged fields stay nil (drawn as dashes) until the first
        // `facts` reply lands.

        // The egress address and Discord reachability need two HTTPS requests,
        // so they are not on the timer. Deferred to the next runloop turn:
        // calling it inline here starts a Task against a `self` that is still
        // inside its own initialiser, and the work simply never ran.
        DispatchQueue.main.async { [weak self] in
            Model.trace("deferred-call-fired")
            self?.refreshProbes()
        }

        isActive = NSApp?.isActive ?? true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowBecameActive()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Backend.repinFailed, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?["error"] as? String ?? "repin"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = self.l.t("failed", ["what": String(reason.prefix(150))])
                self.statusColor = Palette.danger
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Backend.networkChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // DHCP often lands its resolvers a moment after the path
                // moves; the second look is what confirms a change.
                self.checkDNSRoutes()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.checkDNSRoutes()
                    self.checkSiteRoutes()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowResignedActive()
            }
        })

        Notifier.shared.start()
        HotKey.shared.action = { [weak self] in self?.toggleLastMode() }
        if let hotKey { hotKeyRefused = !HotKey.shared.register(hotKey) }
        scheduleTimer()
        // The proxy must not outlive the app. A process that quit leaves its
        // listener gone with it anyway, but a Discord launched with
        // `--proxy-server` would then point at a dead port and fail every
        // request with "connection refused" — so the listener and every tunnel
        // it owns are cancelled here, and the UI is not left claiming it is on.
        //
        // The user's WireGuard tunnel is deliberately NOT touched: it is machine
        // state with its own revert timer, and tearing it down because the app
        // quit is a larger action than the user asked for. The updates-only
        // tunnel is different: it exists only to serve DPI mode, so it goes with
        // the proxy (bounded to 2 s) and DPI brings it back next time.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A block with no app to lift it would strand the user.
                if KillSwitch.load() != nil { self?.backend.act(["killswitch", "off"], timeout: 5) }
                self?.coordinator.shutdownForQuit()
            }
        })
        // After the first paint: adopt whatever a previous run left running,
        // and find out once whether the tunnel helper is usable.
        //
        // Both are deferred to the next runloop turn for the same reason: the
        // first frame must be on screen before anything that can block. The
        // capability probe runs on a worker thread and publishes its answer;
        // nothing in the UI waits for it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Adoption waits for the capability answer, so a tunnel the helper
            // cannot manage is not reported as this app's mode. The probe runs
            // first; `adopt` is called again when its result lands.
            self.refreshDPIStatus()
            self.refresh(announce: false)
            self.probeCapabilities()
        }
    }

    /// Ask the machine once whether the tunnel is usable, off the main thread.
    ///
    /// The result is cached for the life of the process: it changes only when
    /// the user installs the helper or edits sudoers, both of which are followed
    /// by a relaunch in practice. Re-probing on a timer would spawn `sudo` every
    /// couple of seconds to learn the same answer, which is the cost this whole
    /// redesign exists to remove.
    ///
    /// The probe value is captured before the hop so the detached task never
    /// touches `self`; only the publish comes back to the main actor.
    func probeCapabilities() {
        guard !capabilitiesProbed else { return }
        capabilitiesProbed = true
        let helper = backend.helper
        Task {
            let found = await Task.detached(priority: .utility) {
                CapabilityProbe.probe(helper: helper)
            }.value
            self.capabilities = found
            // Now that we know whether the helper can be driven, attribute any
            // tunnel that is already up. Doing it before the answer arrived is
            // what made a helper-less machine report "Tunnel" mode with a lock
            // on the same chip.
            self.coordinator.adoptExistingState(
                canManageTunnel: found.tunnelAvailable)
            self.refreshDPIStatus()
            if found.tunnelAvailable {
                let installed = await Task.detached(priority: .utility) {
                    HelperVersion.installed(helper: helper)
                }.value
                self.helperVersion = installed
                self.helperOutdated = HelperVersion.needsUpdate(installed: installed)
                    && self.canRunTunnelInstaller
                if self.helperOutdated { Notifier.shared.post(.helperUpdate, lang: self.lang) }
                // Quitting lifts the block (a block with no app would strand
                // the user), so a relaunch, including Sparkle's after an
                // update, puts it back on the adopted tunnel.
                if self.coordinator.mode == .tunnel && KillSwitch.load() == nil {
                    await self.applyKillSwitchAfterStart()
                }
                self.coordinator.updateRoutes = { Model.updateRoutes() }
                // Removes an updates tunnel a quit app left behind.
                await self.coordinator.syncUpdateTunnel()
            }
        }
    }

    /// The "Set up tunnel" / "Remove tunnel" buttons.
    @Published var tunnelInstall: TunnelInstallState = .idle

    /// The installed helper is older than the one in this bundle. "Update"
    /// runs the same installer as "Set up tunnel".
    @Published var helperOutdated = false
    /// What `menfez-route version` answered; 0 until asked or when too old.
    @Published var helperVersion = 0

    // MARK: - Keys in the Keychain (1.0.7)

    /// Signed with a Team ID; a stored value so the snapshot can set it.
    var keychainSigned = KeychainStore.signedWithTeam
    /// Moving keys needs a signed build and a helper that takes `--key-stdin`.
    var keychainAvailable: Bool { keychainSigned && helperVersion >= 5 }
    /// "Not now" on the offer; the servers sheet keeps a quiet link instead.
    @Published var keychainOfferDismissed = UserDefaults.standard.bool(forKey: KeychainKeys.dismissedKey) {
        didSet { UserDefaults.standard.set(keychainOfferDismissed, forKey: KeychainKeys.dismissedKey) }
    }

    /// Move every profile's key into the Keychain, or back into its file.
    /// Each file changes only after its key is safely on the other side.
    func moveKeys(toKeychain: Bool) {
        guard !busy, toKeychain ? keychainAvailable : true else { return }
        busy = true
        Task {
            let (done, failed) = await Task.detached(priority: .userInitiated) {
                let census = ProfileKeys.census()
                let store = KeychainStore()
                let files = toKeychain ? census.plain : census.moved
                let done = files.filter {
                    toKeychain ? ProfileKeys.moveToStore(file: $0, store: store)
                               : ProfileKeys.moveToFile(file: $0, store: store)
                }.count
                return (done, files.count - done)
            }.value
            self.busy = false
            UserDefaults.standard.set(toKeychain, forKey: KeychainKeys.onKey)
            if toKeychain { self.keychainOfferDismissed = true }
            if failed > 0 {
                self.status = self.l.t(toKeychain ? "kc_move_failed" : "kc_restore_failed", ["n": "\(failed)"])
                self.statusColor = Palette.danger
            } else {
                self.status = self.l.t(toKeychain ? "kc_moved" : "kc_restored", ["n": "\(done)"])
                self.statusColor = Palette.success
            }
            self.loadProfiles()
        }
    }

    // MARK: - Shortcut

    /// The global shortcut (`HotKeyCombo`, Carbon via `HotKey`); none by default.
    @Published var hotKey: HotKeyCombo? = HotKeyCombo.load()
    /// macOS refused the last combination: another app holds it.
    @Published var hotKeyRefused = false

    /// Register first, save only what macOS accepted; a refusal keeps the old one.
    func setHotKey(_ combo: HotKeyCombo?) {
        hotKeyRefused = !HotKey.shared.register(combo)
        if hotKeyRefused {
            HotKey.shared.register(hotKey)
            return
        }
        hotKey = combo
        HotKeyCombo.save(combo)
    }

    /// The shortcut's action: what the mode bar does, with the target from
    /// `HotKeyCombo.toggleTarget`. The menu-bar icon shows the new mode.
    func toggleLastMode() {
        let last = UserDefaults.standard.string(forKey: HotKeyCombo.lastModeKey).flatMap(RunMode.init)
        setMode(MenuBarModes.path(HotKeyCombo.toggleTarget(current: runMode, last: last)))
    }

    // MARK: - Kill switch

    nonisolated static let killSwitchKey = "killSwitch.enabled"
    /// The user's wish: block when the tunnel drops. Saved; applied at every
    /// tunnel start, lifted (but kept) when leaving tunnel mode or quitting.
    @Published var killSwitchWanted = UserDefaults.standard.bool(forKey: Model.killSwitchKey)
    /// The block is loaded right now (the helper's world-readable record).
    @Published var killSwitchActive = KillSwitch.load() != nil
    /// How the tick reads it; a snapshot swaps in a fixed answer.
    var killSwitchProbe: () -> Bool = { KillSwitch.load() != nil }
    /// Helper 3 knows `killswitch`; an older one gets the Update row instead.
    var killSwitchAvailable: Bool { helperVersion >= 3 }

    func setKillSwitch(_ on: Bool) {
        guard !busy else { return }
        killSwitchWanted = on
        UserDefaults.standard.set(on, forKey: Model.killSwitchKey)
        let live = runMode == .tunnel && tunnelCarriesTraffic
        if on && !live {
            status = l.t("ks_waits")
            statusColor = Palette.secondary
            return
        }
        guard on || killSwitchActive else { return }
        perform(l.t("working"), ["killswitch", on ? "on" : "off"],
                l.t(on ? "ks_on_done" : "ks_off_done")) { ok in
            self.killSwitchActive = KillSwitch.load() != nil
            if on && !ok {
                self.killSwitchWanted = false
                UserDefaults.standard.set(false, forKey: Model.killSwitchKey)
            }
        }
    }

    /// "Unblock": lift the block now and keep the setting for the next start.
    func unblock() {
        guard !busy, killSwitchActive else { return }
        perform(l.t("working"), ["killswitch", "off"], l.t("ks_off_done")) { _ in
            self.killSwitchActive = KillSwitch.load() != nil
        }
    }

    /// After a tunnel start: put the block on when the user asked for it.
    private func applyKillSwitchAfterStart() async {
        guard killSwitchWanted, killSwitchAvailable else { return }
        let backend = self.backend
        let result = await Task.detached(priority: .userInitiated) {
            backend.act(["killswitch", "on"], timeout: 30)
        }.value
        killSwitchActive = KillSwitch.load() != nil
        if result?.ok != true {
            status = l.t("ks_failed", ["what": String((result?.error ?? l.t("helper_no_reply")).prefix(150))])
            statusColor = Palette.warning
        }
    }

    /// The leak test (`LeakTest`), off the main thread. Reads only.
    func runLeakTest() async -> [LeakTest.Line] {
        let scope: Mode? = runMode == .tunnel && tunnelCarriesTraffic ? Mode(rawValue: mode) : nil
        let iface = report?.tunnel
        let endpoint = report?.endpoint.flatMap(hostPart)
        let killSwitch: Bool? = killSwitchAvailable ? KillSwitch.load() != nil : nil
        return await Task.detached(priority: .userInitiated) {
            LeakTest.classify(LeakTest.gather(scope: scope, tunnelIface: iface,
                                              endpoint: endpoint, killSwitch: killSwitch))
        }.value
    }

    /// Before DPI or Direct: a block left on would cut the new mode off.
    private func releaseKillSwitch() async {
        guard KillSwitch.load() != nil else { return }
        let backend = self.backend
        _ = await Task.detached(priority: .userInitiated) {
            backend.act(["killswitch", "off"], timeout: 30)
        }.value
        killSwitchActive = KillSwitch.load() != nil
    }

    /// The bundled helper the installer copies. A var only so a snapshot can
    /// draw the buttons outside a bundle.
    lazy var installerHelper = backend.bundledHelper

    /// The bundle's helper and script exist, so the buttons have something to run.
    var canRunTunnelInstaller: Bool {
        !installerHelper.isEmpty
            && TunnelInstaller.appleScript(.remove, helper: installerHelper, user: "") != nil
    }

    /// One line for the buttons' state, or nil when there is nothing to say.
    var tunnelInstallMessage: String? {
        switch tunnelInstall {
        case .idle: return nil
        case .running(let a): return l.t(a == .install ? "tunnel_install_running" : "tunnel_remove_running")
        case .succeeded(let a): return l.t(a == .install ? "tunnel_install_done" : "tunnel_remove_done")
        case .cancelled: return l.t("tunnel_install_cancelled")
        case .failed(.install, let detail) where detail.hasPrefix("WireGuard tools not found"):
            // The usual first-time failure; the script's sentence is English.
            return l.t("tunnel_install_need_wg")
        case .failed(let a, let detail):
            return l.t(a == .install ? "tunnel_install_failed" : "tunnel_remove_failed", ["detail": detail])
        }
    }

    /// Run the bundled installer through macOS's password dialog, off the main
    /// actor, then ask again whether the tunnel is usable so Tunnel mode lights
    /// up (or locks) without a relaunch.
    func runTunnelInstaller(_ action: TunnelInstallAction) {
        guard let next = tunnelInstall.starting(action) else { return }
        // `down` would pull the tunnel out from under the active mode; the
        // Settings button is disabled then and says so.
        if action == .remove && runMode == .tunnel { return }
        tunnelInstall = next
        let helper = installerHelper
        let user = NSUserName()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TunnelInstaller.run(action, helper: helper, user: user)
            }.value
            DebugLog.log("tunnel installer \(action): \(outcome)", to: "trace.log")
            self.tunnelInstall = .finished(action, outcome)
            guard outcome == .succeeded else { return }
            self.capabilitiesProbed = false
            self.probeCapabilities()
        }
    }

    deinit {
        // Block observers are keyed by their token, not by `self`.
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.invalidate()
    }

    var l: L { L(lang: lang) }

    // MARK: - Launch at login

    /// SMAppService first, a per-user LaunchAgent when that does not take.
    /// See `LoginItem`.
    let loginItem = LoginItem(
        service: SystemLoginService(),
        agentURL: LoginItem.agentURL(home: FileManager.default.homeDirectoryForCurrentUser),
        program: ["/usr/bin/open", "-a", Bundle.main.bundlePath])

    /// Only a real .app can be launched at login; a `swift run` binary cannot.
    var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// And only from /Applications or ~/Applications; see `LoginItem`.
    var canLaunchAtLogin: Bool {
        isAppBundle && LoginItem.isInstalled(
            bundlePath: Bundle.main.bundlePath,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The hint under the toggle, or nil.
    var launchAtLoginHint: String? {
        if isAppBundle && !canLaunchAtLogin { return l.t("login_move_first") }
        return loginNeedsApproval ? l.t("login_needs_approval") : nil
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false

    func readLaunchAtLogin() {
        launchAtLogin = loginItem.isEnabled
        loginNeedsApproval = loginItem.needsApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard canLaunchAtLogin else { return }
        do {
            if on {
                if try loginItem.enable() == .needsApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    status = l.t("login_needs_approval")
                    statusColor = Palette.warning
                }
            } else {
                try loginItem.disable()
            }
        } catch {
            status = l.t("launch_at_login_failed", ["what": error.localizedDescription])
            statusColor = Palette.danger
        }
        readLaunchAtLogin()
    }

    // MARK: - Timer management

    /// The interval the current state calls for.
    ///
    /// Frontmost, or a mode change that is still settling: `activeTick`.
    /// Anything else: `idleTick`. There is no zero case on purpose — a hidden
    /// window still has to notice a tunnel that died, and the local tick costs
    /// four short-lived unprivileged commands.
    var currentInterval: TimeInterval {
        if let settlingUntil, Date() < settlingUntil { return activeTick }
        return isActive ? activeTick : idleTick
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                self.tick()
            }
        }
        // A repeating timer in the default runloop mode stops firing while a
        // menu is tracking or the user is dragging a window; `.common` keeps
        // the status line alive through both.
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func windowBecameActive() {
        isActive = true
        scheduleTimer()
        refresh()
        // Coming back to the window is the moment a stale handshake row is most
        // visible, and it is a user action, so the privileged read is worth it.
        refreshFacts()
        // The network-backed rows only when the last result is older than the
        // TTL: alt-tabbing must not cost three HTTPS requests each time.
        refreshProbes()
    }

    private func windowResignedActive() {
        isActive = false
        scheduleTimer()
    }

    /// Write one line to ~/Library/Logs/Menfez/trace.log when `debugLogging`
    /// is on (see `DebugLog`).
    ///
    /// NSLog needs a live stream to read back, which makes a launch-time
    /// regression impossible to diagnose after the fact. A plain file is the
    /// only mechanism that survives "the user opened it and it was blank".
    static func trace(_ message: String) {
        DebugLog.log(message, to: "trace.log")
    }

    /// When the probes may run and whether a landed result is still current.
    ///
    /// Launch fires twice (the deferred call plus the activation
    /// notification); the schedule lets only one probe per generation run. A
    /// mode or server change bumps the generation, so a probe that measured
    /// the old path is dropped instead of overwriting the new one.
    private var probeSchedule = ProbeSchedule(ttl: 60)

    /// True while a switch is running or its routes are still appearing.
    private var isSettling: Bool {
        busy || (settlingUntil.map { Date() < $0 } ?? false)
    }

    /// A mode or server change is starting: the three probe rows describe the
    /// old path, so they go to "—" and a probe is owed once it settles.
    private func beginPathChange() {
        probeSchedule.invalidate()
        backend.dnsCache.invalidate()
        guard var r = report else { return }
        r.egressIP = nil
        r.geo = nil
        r.discord = DiscordProbe()
        report = r
    }

    /// In DPI mode Discord goes through the proxy, so the probes do too.
    var probeProxyPort: Int? { runMode == .dpi && dpi.running ? dpi.port : nil }

    /// Refresh the rows that need the network: the egress address (with its
    /// country) and whether Discord is reachable.
    ///
    /// Runs at launch, after a mode or server change has settled (the tick
    /// picks up a deferred one), on Refresh (`force`), and on activation only
    /// when the last result is older than the TTL. Never on a plain tick.
    private func refreshProbes(force: Bool = false) {
        guard let token = probeSchedule.start(now: Date(), settling: isSettling,
                                              force: force) else { return }
        Model.trace("refreshProbes-enter gen=\(token)")
        let backend = self.backend
        let proxyPort = probeProxyPort
        Task {
            let probed = await Task.detached(priority: .utility) {
                backend.probes(discordProxyPort: proxyPort)
            }.value
            // NSLog goes to the unified log, which requires a live stream to
            // read; a plain file is the only way to see this after the fact
            // without attaching a debugger.
            DebugLog.log("gen=\(token) egress=\(probed.egressIP ?? "nil") discord=\(probed.discord.code) \(probed.discord.failure?.rawValue ?? "-") geo=\(probed.geo?.country ?? "nil")",
                         to: "probe.log")
            // Measured before a mode or server change: it describes a path
            // that no longer exists.
            guard self.probeSchedule.land(token, now: Date()) else { return }
            // Merge only the three network-backed fields into whatever the
            // local pass produced; replacing the whole report would drop the
            // privileged fields the helper just filled in.
            var merged = self.report ?? Report()
            merged.egressIP = probed.egressIP
            merged.geo = probed.geo
            merged.discord = probed.discord
            // A probe that produced no address at all must not erase one we
            // already had on the same path: a single failed curl is not "you
            // have no IP". After a change the old value was already cleared.
            if probed.egressIP == nil { merged.egressIP = self.report?.egressIP }
            if probed.geo == nil { merged.geo = self.report?.geo }
            self.report = merged
            Model.trace("after-merge report.egress=\(self.report?.egressIP ?? "nil")")
        }
    }

    /// One fast tick: local data only, privileged fields from the cache.
    ///
    /// Profiles are NOT refreshed here. Listing them can pay for a country
    /// lookup (`GeoFromIP`), which is cached but still a disk read and, on the
    /// first call, a network request. The server picker only changes when the
    /// user opens it or switches a server, so the list is refreshed on those
    /// two events and on `refresh()`, not fifteen times a minute.
    ///
    /// The window was hidden; nothing draws, so the egress probe is not
    /// re-paid.
    private func tick() {
        refreshLocal()
        killSwitchActive = killSwitchProbe()
        refreshDPIStatus()
        maybeRefreshFacts()
        // A probe owed by a mode or server change starts once it has settled.
        if probeSchedule.pending { refreshProbes() }
        // A DHCP resolver change does not always move the network path.
        dnsCheckTicks += 1
        if dnsCheckTicks >= 15 {
            dnsCheckTicks = 0
            if mode == Mode.discord.rawValue {
                checkDNSRoutes()
                checkSiteRoutes()
            }
        }
        noticeEvents()
    }

    /// Last tick's facts, for the edges `NotificationPolicy` reads.
    private var wasTunnelLost = false
    private var wasDPIRunning = false

    /// Turn this tick's state changes into notifications (rate limit,
    /// per-event switch and "not while the window is in front" live in
    /// `NotificationPolicy`).
    private func noticeEvents() {
        let lost = tunnelLost
        if let event = NotificationPolicy.tunnelEvent(wasLost: wasTunnelLost, isLost: lost,
                                                      inTunnel: runMode == .tunnel,
                                                      healthy: report?.health.code == .ok) {
            Notifier.shared.post(event, lang: lang)
        }
        wasTunnelLost = lost
        if NotificationPolicy.dpiStoppedUnexpectedly(wasRunning: wasDPIRunning, isRunning: dpi.running,
                                                     dpiSelected: dpiOn) {
            Notifier.shared.post(.dpiStopped, lang: lang)
        }
        wasDPIRunning = dpi.running
    }

    private var dnsCheckTicks = 0
    private var dnsRefresh = DNSRouteRefresh()
    /// The toggle is on but every system resolver is private, so DNS stays
    /// off the tunnel. Shown in the DNS sheet.
    @Published private(set) var dnsStaysOutside = false

    /// Re-send `--dns-routes` when the system resolvers changed while Discord
    /// mode runs with the toggle on; see `DNSRouteRefresh`. One unprivileged
    /// `scutil --dns`, and a root call only on a confirmed change.
    func checkDNSRoutes() {
        let enabled = Model.dnsThroughTunnel()
        guard enabled else {
            dnsRefresh.reset()
            dnsStaysOutside = false
            return
        }
        Task {
            let resolvers = await Task.detached(priority: .utility) {
                DNSManager.systemResolvers()
            }.value
            self.dnsStaysOutside = DNSRouteRefresh.resolversStayOutside(enabled: enabled,
                                                                        resolvers: resolvers)
            guard self.mode == Mode.discord.rawValue, self.tunnelCarriesTraffic else {
                self.dnsRefresh.reset()
                return
            }
            guard !self.busy,
                  let set = self.dnsRefresh.observe(RouteManager.publicResolvers(resolvers)) else { return }
            Model.trace("dns routes changed: \(set.joined(separator: ","))")
            // The chosen sites ride along, or this `mode` would drop them.
            self.perform(self.l.t("working"),
                         ["mode", Mode.discord.rawValue, "--dns-routes", set.joined(separator: ",")]
                            + Model.siteRouteArgs(),
                         self.l.t("dns_routes_updated"))
        }
    }

    /// True while a local pass is running; a slow pass is skipped, not stacked.
    private var localInFlight = false

    /// Build the unprivileged report off the main thread and publish it.
    ///
    /// `localReport` spawns wg, ifconfig, route, ipconfig and networksetup; on
    /// the main thread that held up first paint and every tick. The merge runs
    /// on arrival against the *current* report, so probe fields that landed
    /// meanwhile are kept rather than overwritten by an older snapshot.
    private func refreshLocal() {
        guard !localInFlight else { return }
        localInFlight = true
        let backend = self.backend
        _ = coordinator   // builds `tunnelControl` on first use
        let tunnel = tunnelControl
        Task {
            let (local, carrying) = await Task.detached(priority: .userInitiated) {
                let local = backend.localReport()
                return (local, tunnel.isCarryingTraffic(seen: local))
            }.value
            self.localInFlight = false
            if self.tunnelCarriesTraffic != carrying { self.tunnelCarriesTraffic = carrying }
            self.report = self.merge(local, into: self.report)
            // The launch "checking" ends when the first local pass lands.
            if self.status == self.l.t("checking") { self.status = self.l.t("now") }
        }
    }

    /// Copy the engine's counters into the published status.
    ///
    /// A lock and eight integers in-process — no subprocess, no socket — which
    /// is why it can run on the 2 s tick. It does not touch `dpiOn`: whether the
    /// user selected DPI mode is their choice, not a fact the engine can infer,
    /// and reading it back from `running` would make the button flicker off when
    /// a listener died.
    func refreshDPIStatus() {
        dpi = coordinator.proxy
    }

    /// Fetch the privileged half when it is stale, and only while visible.
    ///
    /// A background window does not refresh the facts: nobody can read them,
    /// and a root process for an invisible window is exactly the cost this
    /// change exists to remove. The first fast tick after the window returns
    /// brings them up to date.
    private func maybeRefreshFacts() {
        guard isActive || (settlingUntil.map { Date() < $0 } ?? false) else { return }
        guard !factsInFlight else { return }
        guard let factsAt, Date().timeIntervalSince(factsAt) < factsInterval else {
            refreshFacts()
            return
        }
    }

    /// Ask the helper for the privileged half, off the main thread.
    private func refreshFacts() {
        guard !factsInFlight, !busy else { return }
        factsInFlight = true
        Task {
            let backend = self.backend
            let fresh = await Task.detached(priority: .utility) {
                backend.facts()
            }.value
            self.factsInFlight = false
            guard let fresh else { return }
            self.facts = fresh
            self.factsAt = Date()
            if let report = self.report {
                self.report = self.merge(report, into: report)
                // The live endpoint is what decides which profile row is the
                // active one, and it only arrived with the facts. Re-listing
                // here is a directory read; no privileged call.
                self.loadProfiles()
            }
            self.checkOrphanTunnel(fresh)
        }
    }

    private var orphanCheckInFlight = false

    /// At launch and on every facts refresh: a tunnel moving our traffic
    /// through a server that is no longer in the list (deleted, replaced or
    /// edited elsewhere) is taken down. See `TunnelRecovery.shouldRelease`.
    /// An idle orphan (no routes) is not released, only stopped: `teardown`
    /// takes its interface down, once per interface name.
    private func checkOrphanTunnel(_ f: RouteManager.TunnelFacts) {
        guard capabilities.tunnelAvailable, !busy, !orphanCheckInFlight,
              let iface = f.tunnel, iface != orphanTeardownTried else { return }
        orphanCheckInFlight = true
        Task {
            // A fresh listing: `profiles` is empty until the first load lands.
            let (release, orphan) = await Task.detached(priority: .utility) {
                let state = RouteStateStore.load()
                let profiles = WireGuardProfiles.list(liveHost: nil)
                return (TunnelRecovery.shouldRelease(liveIface: f.tunnel, state: state,
                                                     livePeerKey: f.peerPubkey, profiles: profiles),
                        TunnelRecovery.isOrphan(liveIface: f.tunnel, stateIface: state.iface,
                                                livePeerKey: f.peerPubkey, profiles: profiles))
            }.value
            defer { self.orphanCheckInFlight = false }
            guard orphan, !self.busy else { return }
            if release {
                Model.trace("orphan tunnel: its server is not in the profile folder; releasing")
                guard await self.releaseTunnel() else { return self.refresh(announce: false) }
                self.status = self.l.t("tunnel_orphan_closed")
                self.statusColor = Palette.warning
                Notifier.shared.post(.serverRemoved, lang: self.lang)
            }
            self.orphanTeardownTried = iface
            await self.teardownTunnel()
            self.refresh(announce: false)
        }
    }

    /// The interface the last orphan teardown was for, so a failing one is not
    /// retried on every facts refresh.
    private var orphanTeardownTried: String?

    /// Stop our WireGuard interface and drop its config: its server is gone.
    /// An older helper does not know `teardown`; that is what "Update" is for.
    private func teardownTunnel() async {
        let backend = self.backend
        let result = await Task.detached(priority: .utility) {
            backend.act(["teardown"])
        }.value
        Model.trace("teardown: \(result?.ok == true ? "ok" : (result?.error ?? "no reply"))")
    }

    /// Take the tunnel off our traffic before its server goes away: Tunnel
    /// mode becomes Direct, beside DPI only the updates tunnel stops. True
    /// when nothing carries our traffic any more.
    private func releaseTunnel() async -> Bool {
        beginPathChange()
        busy = true
        let state = await coordinator.releaseTunnel()
        busy = false
        apply(state)
        return state.ok
    }

    /// Fold the cached privileged facts into a locally built report.
    ///
    /// A report built by the helper already has everything; this only runs for
    /// one built in-process. Every privileged field is copied from `facts` and
    /// left alone when there are none — never filled from a guess.
    private func merge(_ local: Report, into previous: Report?) -> Report {
        var merged = local

        // Carry the three network-backed rows across a local pass. They are
        // only refreshed by `refreshProbes`, so without this the 2-second tick
        // would blank the IP, the location and the Discord verdict right after
        // every probe. A mode or server change clears them first
        // (`beginPathChange`), so what is carried is never another path's.
        if let previous {
            merged.egressIP = previous.egressIP
            merged.geo = previous.geo
            merged.discord = previous.discord
        }
        guard let f = facts else {
            // No privileged sample yet. Keep `unknown` so the UI says "checking"
            // rather than "no handshake", and keep the previous row values so a
            // transient failure does not blank the card.
            if let previous, previous.tunnel == local.tunnel {
                merged.peerPubkey = previous.peerPubkey
                merged.handshakeEpoch = previous.handshakeEpoch
                merged.transfer = previous.transfer
            }
            return merged
        }

        // A facts snapshot for a different interface is stale: the tunnel was
        // replaced under us. Using it would attribute one tunnel's counters to
        // another, which is worse than a dash.
        guard f.tunnel != nil, f.tunnel == local.tunnel else { return merged }

        merged.endpoint = f.endpoint
        merged.peerPubkey = f.peerPubkey
        merged.handshakeEpoch = f.handshakeEpoch
        merged.transfer = f.transfer
        // The age is derived from the epoch on every redraw, so a cached fact
        // still produces a moving number instead of a frozen one.
        merged.handshakeAgeS = f.handshakeEpoch.map {
            max(0, Int(Date().timeIntervalSince1970) - $0)
        }
        merged.health = RouteManager.health(
            iface: local.tunnel ?? "",
            exists: local.health.code != .gone && local.health.code != .down,
            handshakeEpoch: f.handshakeEpoch)
        return merged
    }

    /// Address part of "host:port", for matching against a profile endpoint.
    private func hostPart(_ endpoint: String) -> String? {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let colon = endpoint.lastIndex(of: ":"),
              endpoint[endpoint.startIndex..<colon].contains(":") == false else {
            return endpoint.isEmpty ? nil : endpoint
        }
        let host = String(endpoint[endpoint.startIndex..<colon])
        return host.isEmpty ? nil : host
    }

    func setLang(_ new: Lang) {
        guard new != lang else { return }
        lang = new
        savePrefs()
        status = l.t("now")
    }

    private func savePrefs() {
        let dir = prefsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["lang": lang.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: prefsURL)
        }
    }

    /// Full refresh, for the Refresh button and after a mutation.
    ///
    /// The local half lands immediately (so the card does not blink); the
    /// privileged half is fetched in the background and merged when it arrives.
    /// `announce: false` keeps the status line: after a mutation it holds the
    /// result the user must read, at launch it says "checking".
    func refresh(announce: Bool = true) {
        guard !busy else { return }
        refreshLocal()
        loadProfiles()
        if announce {
            status = l.t("now")
            statusColor = Palette.secondary
            // The Refresh button: a user asking for current numbers.
            refreshProbes(force: true)
        }
        refreshFacts()
    }

    /// Re-read the server list (a user action, or the first facts reply).
    ///
    /// Off the main thread, in two steps: the rows from disk land first, then
    /// countries are filled in when the (cached, possibly network) lookup
    /// returns. Overlapping calls coalesce: only the newest listing is
    /// published, and only one country lookup runs at a time.
    func loadProfiles() {
        profilesGeneration += 1
        let generation = profilesGeneration
        let backend = self.backend
        let liveHost = report?.endpoint.flatMap(hostPart)
        // The peer key ties a row to the live tunnel through a rename and a
        // hostname endpoint; only from facts about the interface on screen.
        let liveKey = facts.flatMap { $0.tunnel != nil && $0.tunnel == report?.tunnel ? $0.peerPubkey : nil }
        Task {
            let list = await Task.detached(priority: .userInitiated) {
                backend.profiles(liveHost: liveHost, livePeerKey: liveKey)
            }.value
            guard generation == self.profilesGeneration else { return }
            // Remembered for the post-reboot auto-reconnect (see TunnelRecovery).
            // Only in Tunnel mode: elsewhere an idle interface's server is not
            // the selection, which a pick there saves on its own.
            if self.runMode == .tunnel, let live = list.first(where: { $0.active })?.name {
                self.selectedProfile = live
            }
            self.profiles = self.withCountries(list)
            self.fillCountries()
        }
    }

    /// Bumped by every `loadProfiles`; an older listing that finishes late is
    /// dropped instead of overwriting a newer one (e.g. the active row).
    private var profilesGeneration = 0
    private var geoInFlight = false
    /// Countries found so far, by host, for this process.
    private var geoFound: [String: String] = [:]

    private func withCountries(_ list: [Profile]) -> [Profile] {
        list.map { profile in
            var profile = profile
            if profile.country == nil, let host = profile.host {
                profile.country = geoFound[host]
            }
            return profile
        }
    }

    private func fillCountries() {
        let missing = profiles.filter { $0.country == nil && $0.host != nil }
        guard !geoInFlight, !missing.isEmpty else { return }
        geoInFlight = true
        let backend = self.backend
        Task {
            let found = await Task.detached(priority: .utility) {
                backend.countries(for: missing)
            }.value
            self.geoInFlight = false
            self.geoFound.merge(found) { _, new in new }
            self.profiles = self.withCountries(self.profiles)
        }
    }

    /// Refresh the DNS sheet's data (a user action: it runs ~21 `dig` queries).
    func refreshDNS() {
        Task {
            let backend = self.backend
            let result = await Task.detached(priority: .userInitiated) {
                backend.dns()
            }.value
            if let result { self.dns = result }
        }
    }

    // MARK: - Modes

    /// The primary action: start the proxy and launch Discord through it.
    ///
    /// This is the whole free tier in one click, and it is the reason the app
    /// exists on a machine with no helper: `switchTo(.dpi)` binds a loopback
    /// port in-process, and `launchDiscord` passes `--proxy-server` to it. No
    /// sudo, no password, no routes.
    ///
    /// The proxy starts before Discord is launched because the launch needs a
    /// port to point at; if the launch then finds Discord already running, the
    /// proxy stays up and the status line says to quit Discord first. Leaving
    /// the proxy running is the right call there: it is the state the next
    /// click needs, and the user asked for DPI mode, not for it to be undone.
    func enableDPIAndLaunchDiscord() {
        guard !busy else { return }
        beginPathChange()
        Task {
            await self.releaseKillSwitch()
            let state = await coordinator.switchTo(.dpi)
            self.apply(state)
            guard state.ok else { return }
            self.launchDiscord(updatesViaTunnel: state.updatesViaTunnel)
        }
    }

    /// Enter DPI mode only.
    func enableDPI() {
        guard !busy else { return }
        beginPathChange()
        Task {
            await self.releaseKillSwitch()
            let state = await coordinator.switchTo(.dpi)
            self.apply(state)
        }
    }

    /// Leave DPI mode. Established tunnels are allowed to finish.
    func disableDPI() {
        guard !busy else { return }
        beginPathChange()
        busy = true
        let from = runMode, port = dpi.port
        Task {
            await self.releaseKillSwitch()
            let state = await coordinator.switchTo(.direct)
            self.busy = false
            self.apply(state)
            self.offerDiscordRestart(from: from, to: state.mode, port: port)
        }
    }

    /// A Tunnel click found no server and opened the picker: the server the
    /// user then adds or picks finishes that click. Cleared by any other mode
    /// click and when the picker closes.
    var pendingTunnelStart = false

    /// Bumped when a Tunnel click finished from the server sheet went
    /// through; the window closes the sheet. A failure leaves it open.
    @Published var serverSheetCloses = 0

    /// The chosen server (`lastProfileKey`): what a tunnel start uses.
    @Published var selectedProfile: String? = UserDefaults.standard.string(forKey: Model.lastProfileKey) {
        didSet { UserDefaults.standard.set(selectedProfile, forKey: Model.lastProfileKey) }
    }

    /// Whether a server row shows as chosen (see `TunnelRecovery.isChosen`).
    func isChosen(_ p: Profile) -> Bool {
        TunnelRecovery.isChosen(name: p.name, active: p.active, inTunnel: runMode == .tunnel,
                                selection: selectedProfile)
    }

    /// Make `name` the chosen server and finish the Tunnel click that asked
    /// for one. False when no such click is waiting.
    private func continueTunnelStart(with name: String) -> Bool {
        guard pendingTunnelStart else { return false }
        selectedProfile = name
        setMode("tunnel", closesServerSheet: true)
        return true
    }

    /// What Tunnel mode carries: Discord only, Discord + chosen sites, or the
    /// whole internet. Saved.
    @Published var scopeChoice: TunnelScope.Choice = TunnelScope.choice()
    /// The helper mode of that choice (chosen sites run in Discord mode).
    var tunnelScope: Mode { scopeChoice.mode }

    /// Pick the scope. With the tunnel up in another scope, its routes (and
    /// for Whole internet the resolver) are swapped by `mode`, without
    /// restarting WireGuard. A failed swap puts the old choice back.
    func setTunnelScope(_ choice: TunnelScope.Choice) {
        guard !busy, choice != scopeChoice else { return }
        guard choice != .sites || sitesAvailable else {
            status = l.t("sites_needs_update")
            statusColor = Palette.warning
            return
        }
        let previous = scopeChoice
        TunnelScope.save(choice: choice)
        scopeChoice = choice
        guard TunnelScope.needsReroute(inTunnel: runMode == .tunnel, routeMode: mode,
                                       from: previous, to: choice) else {
            if choice == .sites { checkSiteRoutes() }
            return
        }
        let name = l.t("m_" + choice.rawValue)
        Task {
            // The first pick of chosen sites may have no lookup yet.
            if choice == .sites { await resolveSites() }
            perform(l.t("switching", ["what": name]), ["mode", choice.mode.rawValue] + Model.dnsRouteArgs(),
                    l.t("mode_set", ["what": name])) { ok in
                if ok { self.siteRefresh.didSend(choice == .sites ? SiteAddressCache.shared.addresses : []) }
                guard !ok else { return }
                TunnelScope.save(choice: previous)
                self.scopeChoice = previous
            }
        }
    }

    // MARK: - Chosen sites (Discord + chosen sites)

    /// Helper 4 knows `--site-routes`; an older one ignores it.
    var sitesAvailable: Bool { helperVersion >= 4 }
    private static let loadedSites = SiteList.load()
    /// The user's list (`sites.json`), as normalised entries.
    @Published var sites: [String] = Model.loadedSites.list.sites
    /// `sites.json` could not be read; it was kept as `.bak` (shown in the sheet).
    let sitesRecovered = Model.loadedSites.recovered
    /// Per entry, how many addresses the last lookup gave (0: did not resolve).
    @Published var siteCounts: [String: Int] = [:]
    @Published var sitesResolvedAt: Date?
    @Published var sitesLookupRunning = false
    private var siteRefresh = SiteRoutes.Refresh()

    /// Add what the user typed. Returns the problem to show, or nil.
    func addSite(_ raw: String) -> String? {
        guard let entry = SiteRoutes.normalize(raw) else { return l.t("sites_invalid") }
        guard !sites.contains(entry) else { return nil }
        guard sites.count < SiteRoutes.maxSites else {
            return l.t("sites_full", ["what": String(SiteRoutes.maxSites)])
        }
        sites.append(entry)
        sitesEdited()
        return nil
    }

    func removeSite(_ entry: String) {
        sites.removeAll { $0 == entry }
        siteCounts[entry] = nil
        sitesEdited()
    }

    private func sitesEdited() {
        guard SiteList(sites: sites).save() else {
            status = l.t("sites_save_failed")
            statusColor = Palette.danger
            return
        }
        checkSiteRoutes(now: true)
    }

    /// Look the list up with DoH, off the main thread, and keep the answer.
    func resolveSites() async {
        let list = sites
        sitesLookupRunning = true
        let found = await Task.detached(priority: .utility) { SiteRoutes.resolve(list) }.value
        sitesLookupRunning = false
        guard list == sites else { return }   // edited meanwhile; the next check redoes it
        SiteAddressCache.shared.addresses = found.addresses
        siteCounts = found.counts
        sitesResolvedAt = Date()
    }

    /// Every minute in Discord mode, after a network change, and after an
    /// edit (`now`): look the sites up again and re-send `mode discord` when
    /// the addresses moved (`SiteRoutes.Refresh`), or when the live routes
    /// carry sites this choice does not want. Names never reach the helper
    /// or the log; only counts are traced.
    func checkSiteRoutes(now: Bool = false) {
        guard sitesAvailable else { return }
        Task {
            if scopeChoice == .sites { await resolveSites() }
            guard runMode == .tunnel, mode == Mode.discord.rawValue, tunnelCarriesTraffic, !busy else {
                siteRefresh.reset()
                return
            }
            let live = (RouteStateStore.load().sites ?? []).map { String($0.split(separator: "/")[0]) }
            let resolved = SiteAddressCache.shared.addresses
            let send: [String]?
            if scopeChoice != .sites {
                send = live.isEmpty ? nil : []
            } else if now {
                send = Set(resolved) == Set(live) ? nil : resolved
                if send != nil { siteRefresh.didSend(resolved) }
            } else {
                send = siteRefresh.observe(resolved: resolved, live: live)
            }
            guard let send else { return }
            Model.trace("site routes: \(send.count) address(es) for \(sites.count) site(s)")
            var args = ["mode", Mode.discord.rawValue] + Model.dnsRouteArgs()
            if let at = args.firstIndex(of: "--site-routes") { args.removeSubrange(at...(at + 1)) }
            perform(l.t("working"), args + SiteRoutes.argument(send), l.t("sites_updated"))
        }
    }

    /// Pick a mode from the bar: proxy, tunnel, or nothing.
    ///
    /// One entry point for all three so the ordering rule lives in one place
    /// (`ModeCoordinator`) instead of being re-derived here per button. The
    /// tunnel's own `Mode` (`discord`/`all`) is passed separately because it is
    /// a property of the tunnel, not of "which interception is live".
    func setMode(_ path: String, tunnelMode: Mode? = nil, closesServerSheet: Bool = false) {
        guard !busy else { return }
        pendingTunnelStart = false
        switch path {
        case "dpi":
            enableDPI()
        case "direct", "off":
            disableDPI()
        case "tunnel", "discord", "all":
            guard capabilities.tunnelAvailable else {
                // The tunnel was never set up. This is not an error and must not
                // read like one: it is a missing optional extra, and the row
                // that explains it is one click away in Help.
                status = tunnelReason
                statusColor = Palette.warning
                return
            }
            let mode: Mode = path == "all" ? .all : (tunnelMode ?? tunnelScope)
            beginPathChange()
            busy = true
            let message = l.t("switching", ["what": l.t("m_" + mode.rawValue)])
            status = message
            statusColor = Palette.warning
            let from = runMode, port = dpi.port
            Task {
                let state = await coordinator.switchTo(.tunnel, tunnelMode: mode)
                defer { self.offerDiscordRestart(from: from, to: state.mode, port: port) }
                self.busy = false
                self.settlingUntil = Date().addingTimeInterval(self.settleWindow)
                self.scheduleTimer()
                self.apply(state)
                if state.ok && state.mode == .tunnel {
                    if closesServerSheet { self.serverSheetCloses += 1 }
                    await self.applyKillSwitchAfterStart()
                }
                if state.ok { self.refresh(announce: false) }
                if state.recovery == .chooseServer {
                    self.pendingTunnelStart = true
                    self.serverRequests += 1
                }
            }
        default:
            break
        }
    }

    /// Publish a coordinator result: status, colour, counters, timer cadence.
    ///
    /// One function so a transition cannot update half the state: before this,
    /// `dpiOn`, `dpi`, `status` and `statusColor` were assigned in three
    /// different places and a refused bind could leave the panel claiming DPI
    /// mode with a dead port.
    private func apply(_ state: ModeState) {
        dpi = state.proxy
        if state.ok && state.mode != .direct {
            UserDefaults.standard.set(state.mode.rawValue, forKey: HotKeyCombo.lastModeKey)
        }
        probe = state.mode == .dpi ? probe : nil
        status = l.modeState(state, hasProfiles: !profiles.isEmpty)
        if state.portChanged { status += " · " + l.t("dpi_port_changed") }
        // Amber, not red, for the two states that are instructions rather than
        // failures: nothing is intercepting because the user turned it off, or
        // because the optional tunnel is not set up.
        if state.ok {
            statusColor = state.mode == .direct ? Palette.secondary : Palette.success
        } else {
            statusColor = state.mode == .direct ? Palette.warning : Palette.danger
        }
        scheduleTimer()
        // A switch may have set or restored resolvers: read them afresh.
        backend.dnsCache.invalidate()
        // Deferred by the schedule while the switch is still settling.
        refreshProbes()
    }

    /// After leaving DPI mode: ask to restart a Discord still bound to the
    /// closed proxy. Runs after the switch has finished, so it never delays it.
    private func offerDiscordRestart(from: RunMode, to: RunMode, port: Int?) {
        guard from == .dpi, to != .dpi else { return }
        Task {
            let ps = await Task.detached(priority: .utility) {
                SystemRunner().run("ps", ["-axo", "pid=,args="], timeout: 5).output
            }.value
            self.discordRestartPID = DiscordLauncher.restartCandidate(
                psOutput: ps, from: from, to: to, port: port)
        }
    }

    /// The restart button: quit Discord, wait up to 5 s, force it, then open it
    /// again with no proxy flag.
    func restartDiscord(pid: Int32) {
        discordRestartPID = nil
        Task {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
                for _ in 0..<50 where !app.isTerminated {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if !app.isTerminated {
                    app.forceTerminate()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                SystemRunner().run("open", ["-b", DiscordLauncher.bundleID], timeout: 15)
            }.value
            if result.ok {
                self.status = self.l.t("discord_restarted")
                self.statusColor = Palette.success
            } else {
                self.status = self.l.t("launch_openFailed", ["what": result.tail(1)])
                self.statusColor = Palette.danger
            }
        }
    }

    func declineDiscordRestart() {
        discordRestartPID = nil
        status += " · " + l.t("discord_restart_later")
        statusColor = Palette.warning
    }

    /// Launch Discord pointed at the proxy, starting the proxy if it is off.
    ///
    /// The refusal cases are the interesting ones: see DiscordLauncher for why
    /// an already-running Discord cannot be redirected.
    func launchDiscord(updatesViaTunnel: Bool? = nil) {
        guard let proxy = dpiMode else { return }
        // With the updates tunnel the check succeeds, so the write is not needed.
        let tunnelCovers = DiscordUpdateRoutes.tunnelCoversUpdates(
            lastResult: updatesViaTunnel,
            hybridUp: TunnelRecovery.isUpdatesHybrid(routeMode: mode, carrying: tunnelCarriesTraffic),
            enabled: DiscordUpdateRoutes.isEnabled(),
            hasProfile: !WireGuardProfiles.list(liveHost: nil).isEmpty,
            hasHelper: FileManager.default.isExecutableFile(atPath: backend.helper))
        Task {
            // Off the main actor: macOS may hold the read behind an
            // "access data from other apps" prompt. Only in DPI mode, and at
            // most once per settings path: each read can raise macOS's
            // "access blocked" notification.
            var failOpen = DiscordLauncher.FailOpenResult.unchanged
            let memory = DiscordLauncher.FailOpenMemory()
            let url = DiscordLauncher.settingsFile
            if dpi.running, !tunnelCovers, !proxy.discordRunning(), memory.shouldTry(url) {
                failOpen = await Task.detached { DiscordLauncher.allowUpdateFailOpen(settings: url) }.value
                memory.record(failOpen, for: url)
                discordSettingsHint = memory.showsHint
            }
            let result = await proxy.launchDiscord()
            switch result {
            case .success:
                status = l.t("discord_launched", ["port": "\(dpi.port ?? 0)"])
                statusColor = Palette.success
                if case .denied(let why) = failOpen {
                    Self.trace("discord settings.json denied: \(why)")
                    statusColor = Palette.warning
                } else if case .failed(let why) = failOpen {
                    Self.trace("discord settings.json not writable: \(why)")
                    status += " · " + l.t("discord_settings_denied")
                    statusColor = Palette.warning
                }
            case .failure(let error):
                status = l.launchError(error)
                // "quit Discord first" and "start DPI mode first" are instructions,
                // not failures: amber sends the user to the click that fixes it,
                // red would suggest something broke.
                statusColor = (error == .alreadyRunning || error == .proxyNotRunning)
                    ? Palette.warning : Palette.danger
            }
        }
    }

    /// The hint's "Try again": forget the denial and launch once more.
    func retryDiscordSettings() {
        DiscordLauncher.FailOpenMemory().reset()
        discordSettingsHint = false
        launchDiscord()
    }

    func dismissDiscordSettingsHint() {
        DiscordLauncher.FailOpenMemory().dismissHint()
        discordSettingsHint = false
    }

    /// Ask the network whether the split is helping. Never called on a timer.
    ///
    /// Two curl requests take up to ~16 s in the worst case, so this runs off
    /// the main actor and the button stays disabled meanwhile. The port is read
    /// here, on the main actor, and passed by value: a `DPIMode` reference must
    /// not cross into a detached task, and a value cannot be read after a
    /// concurrent stop has closed the listener.
    func runProbe() {
        guard !probing else { return }
        guard dpiOn, dpi.running else {
            status = l.t("probe_needs_proxy")
            statusColor = Palette.warning
            return
        }
        probing = true
        status = l.t("probing")
        statusColor = Palette.warning

        let port = dpi.running ? dpi.port : nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DPIProbe.run(port: port)
            }.value
            self.probing = false
            self.probe = outcome
            // The verdict is shown in the DPI card; the footer goes back to
            // "last updated".
            self.status = ""
            self.refreshDPIStatus()
        }
    }

    func importConfig(from path: String) {
        let backend = self.backend
        // A file read and a 0600 write: off the main actor, so a slow disk
        // (or a file on a network share) cannot stall the window.
        Task {
            let (result, replaced) = await Task.detached(priority: .userInitiated) {
                let first = backend.importConfig(from: path, overwrite: false)
                // `.exists` is the one case the user can resolve, so it
                // replaces rather than just reporting a dead end.
                if case .failure(let error) = first, error.kind == .exists {
                    return (first, backend.importConfig(from: path, overwrite: true).isSuccess)
                }
                return (first, false)
            }.value
            switch result {
            case .success(let profile):
                self.status = self.l.t("import_ok", ["what": profile.name])
                self.statusColor = Palette.success
                self.selectImported(profile.name)
                self.refresh(announce: false)
            case .failure(let error):
                if replaced {
                    self.status = self.l.t("import_ok", ["what": (path as NSString).lastPathComponent])
                    self.statusColor = Palette.success
                    self.refresh(announce: false)
                } else {
                    self.status = self.l.t("failed", ["what": error.message])
                    self.statusColor = Palette.danger
                }
            }
        }
    }

    /// A new server becomes the selection when none is chosen. A waiting
    /// Tunnel click then goes on with it; in Tunnel mode it is switched to,
    /// as picking it would. Elsewhere nothing connects.
    private func selectImported(_ name: String) {
        let last = selectedProfile
        let available = WireGuardProfiles.list(liveHost: nil).map(\.name)
        let chosen = TunnelRecovery.selectionAfterImport(name, lastProfile: last, available: available)
        if continueTunnelStart(with: chosen) { return }
        guard chosen != last else { return }
        selectedProfile = chosen
        if runMode == .tunnel, chosen == name { switchServer(name) }
    }

    func chooseAndImportConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = l.t("import_prompt")

        // `runModal` from inside a sheet works, but the sheet's own presentation
        // must not be touched afterwards: setting the flag to true while it is
        // already presented makes SwiftUI tear it down and re-present it, which
        // looked like the picker reopening itself on every dismissal. The list is
        // refreshed by `m.importConfig`, so nothing here re-presents anything —
        // and `SheetRouter.present` would ignore it if it did.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importConfig(from: url.path)
    }

    // --- edit / delete a server ------------------------------------------

    /// Rename a profile's file. Returns the message to show under the field
    /// when the name is refused, nil on success.
    func renameProfile(_ p: Profile, to newName: String) -> String? {
        switch WireGuardProfiles.rename(p.name, to: newName) {
        case .success(let renamed):
            // The post-reboot reconnect remembers the profile by name.
            if selectedProfile == p.name {
                selectedProfile = renamed.name
            }
            status = l.t("srv_renamed", ["name": renamed.name])
            statusColor = Palette.success
            loadProfiles()
            return nil
        case .failure(let error):
            switch error.kind {
            case .badName: return l.t("srv_bad_name")
            case .exists:  return l.t("srv_name_taken")
            default:       return l.t("failed", ["what": error.message])
            }
        }
    }

    /// Pick a `.conf` and write it over this profile, keeping its name.
    func replaceProfileConfig(_ p: Profile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = l.t("import_prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                KeychainKeys.follow(WireGuardProfiles.importConfig(from: url.path, overwrite: true, as: p.name))
            }.value
            switch result {
            case .success:
                self.status = self.l.t("srv_replaced", ["name": p.name])
                self.statusColor = Palette.success
                self.loadProfiles()
                // The live tunnel still runs the old copy: re-point it.
                guard p.active else { return }
                if self.runMode == .tunnel {
                    self.switchServer(p.name)
                } else if self.tunnelCarriesTraffic, await self.releaseTunnel() {
                    await self.coordinator.syncUpdateTunnel()
                    self.refresh(announce: false)
                }
            case .failure(let error):
                self.status = self.l.t("failed", ["what": error.message])
                self.statusColor = Palette.danger
            }
        }
    }

    /// Delete a profile. The one the tunnel is using is let go first: the app
    /// switches to direct mode and deletes only once that switch went through.
    func deleteProfile(_ p: Profile) {
        guard !busy else { return }
        Task {
            // A live tunnel whose server could not be matched may be this one.
            // The hybrid updates tunnel counts too: it runs beside DPI mode.
            let backs = p.active || activeProfile == nil
            if backs, runMode == .tunnel || tunnelCarriesTraffic {
                guard await releaseTunnel() else { return }
            }
            let wasLastUsed = UserDefaults.standard.string(forKey: Model.lastProfileKey) == p.name
            let (ok, noneLeft) = await Task.detached(priority: .userInitiated) {
                let ok = WireGuardProfiles.delete(p.name)
                return (ok, WireGuardProfiles.list(liveHost: nil).isEmpty)
            }.value
            // The interface (even idle) belonged to this server: stop it.
            if ok, capabilities.tunnelAvailable,
               TunnelRecovery.shouldTearDown(deletedActive: p.active, deletedLastUsed: wasLastUsed,
                                             noProfilesLeft: noneLeft) {
                await teardownTunnel()
            }
            if ok, self.selectedProfile == p.name {
                self.selectedProfile = nil
            }
            self.status = self.l.t(ok ? "srv_deleted" : "srv_delete_failed", ["name": p.name])
            self.statusColor = ok ? Palette.secondary : Palette.danger
            self.refresh(announce: false)
        }
    }

    /// Ask where to save, then build the masked report off the main actor
    /// (it runs the local report commands and reads the log files).
    func exportDebugLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogExport.fileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = AppVersion.short(from: Bundle.main.infoDictionary)
        let mode = runMode.rawValue
        let dpi = self.dpi
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                let text = LogExport.build(appVersion: version, runMode: mode, dpi: dpi)
                return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
            }.value
            self.status = self.l.t(ok ? "log_exported" : "log_export_failed")
            self.statusColor = ok ? Palette.secondary : Palette.danger
        }
    }

    func switchServer(_ name: String) {
        guard !busy else { return }
        if continueTunnelStart(with: name) { return }
        // Outside Tunnel mode a pick only selects: no `switch`, no tunnel.
        // The next Tunnel click starts this server (`runsStaleServer`).
        guard runMode == .tunnel else {
            selectedProfile = name
            status = l.t("server_set", ["what": name])
            statusColor = Palette.secondary
            return
        }
        perform(l.t("switching", ["what": name]), ["switch", name] + Model.dnsRouteArgs(profile: name),
                l.t("server_set", ["what": name]))
    }

    /// The DNS-through-tunnel toggle changed: a live Discord-mode route set is
    /// swapped at once (`mode` adds or removes only the resolver /32s).
    func dnsRoutingChanged() {
        guard !busy, mode == Mode.discord.rawValue else { return }
        perform(l.t("working"), ["mode", Mode.discord.rawValue] + Model.dnsRouteArgs(),
                l.t("dns_tunnel"))
    }

    func setDNS(_ preset: String) {
        guard !busy else { return }
        let args = preset == "system" ? ["dns", "auto"] : ["dns", "set", preset]
        perform(l.t("working"), args, l.t("dns_set", ["what": preset]))
    }

    /// Run a mutating helper command without blocking the UI.
    ///
    /// `act` returns the helper's own ActionResult so the failure text is the
    /// message the routing layer produced ("cannot pin the endpoint", not
    /// "exit code 1"), which is what the user needs to act on.
    private func perform(_ message: String, _ args: [String], _ done: String,
                         completion: ((Bool) -> Void)? = nil) {
        beginPathChange()
        if args.contains("--dns-routes") { dnsRefresh.reset() }
        busy = true
        status = message
        statusColor = Palette.warning
        Task {
            let backend = self.backend
            let result = await Task.detached(priority: .userInitiated) {
                backend.act(args)
            }.value

            self.busy = false
            self.settlingUntil = Date().addingTimeInterval(self.settleWindow)
            self.scheduleTimer()
            // A DNS action or a switch changed the resolvers: the card must
            // show the new ones on this refresh, not after the cache expires.
            self.backend.dnsCache.invalidate()
            let notes = result?.notes ?? []
            if result?.ok == true {
                // A note like "safety net not armed" is the difference between
                // "the revert is scheduled" and "you have no safety net". It
                // used to be written to a journal nothing read, so a success
                // toast hid it; now it is appended to what the user sees.
                let suffix = notes.isEmpty ? "" : " · " + notes[0]
                self.status = done + suffix
                self.statusColor = notes.isEmpty ? Palette.success : Palette.warning
            } else {
                let reason = result?.error == ProfileKeys.readFailure ? self.l.t("kc_failed")
                    : result?.error ?? self.l.t("helper_no_reply")
                self.status = self.l.t("failed", ["what": String(reason.prefix(150))])
                self.statusColor = Palette.danger
            }
            completion?(result?.ok == true)
            self.refresh(announce: false)
        }
    }

    // --- derived presentation values -------------------------------------

    var mode: String { report?.mode ?? Mode.off.rawValue }

    var activeProfile: Profile? { profiles.first(where: { $0.active }) }

    // --- tunnel server identity -------------------------------------------

    /// Server endpoint host -> address (itself when it is already an IP).
    @Published var serverAddr: [String: String] = [:]
    /// ipinfo answers for server addresses, by IP. Per launch, in memory.
    @Published var serverGeos: [String: Geo] = [:]
    /// When a host was last looked up, so a failure is retried a minute later
    /// rather than on every two-second refresh.
    private var serverTried: [String: Date] = [:]

    private var serverHost: String? {
        CardIdentity.serverHost(liveEndpointHost: report?.endpoint.flatMap(hostPart),
                                profileHost: activeProfile?.host)
    }

    /// What the card's IP / location / ISP rows show: the tunnel server's
    /// address and geo in tunnel mode, this machine's exit otherwise.
    var cardIdentity: CardIdentity {
        let ip = serverHost.flatMap { serverAddr[$0] }
        return CardIdentity.choose(runMode: runMode, routeMode: mode,
                                   egressIP: report?.egressIP, egressGeo: report?.geo,
                                   serverIP: ip, serverGeo: ip.flatMap { serverGeos[$0] })
    }

    /// Look up the active server's address and geo once (DoH for a name,
    /// then the same ipinfo call the egress row uses). Tunnel mode only.
    func fillServerGeo() {
        // Whole internet: the card shows the real egress lookup instead.
        guard runMode == .tunnel, mode != Mode.all.rawValue, let host = serverHost else { return }
        if let ip = serverAddr[host], serverGeos[ip] != nil { return }
        if let last = serverTried[host], Date().timeIntervalSince(last) < 60 { return }
        serverTried[host] = Date()
        Task {
            let found: (String, Geo?)? = await Task.detached(priority: .utility) {
                var ip = Validate.ipAddress(host)
                if ip == nil {
                    ip = await withCheckedContinuation { done in
                        DoHResolver.shared.resolve(host) { done.resume(returning: $0?.first) }
                    }
                }
                guard let ip else { return nil }
                return (ip, Probes.geo(ip: ip))
            }.value
            guard let (ip, geo) = found else { return }
            self.serverAddr[host] = ip
            if let geo { self.serverGeos[ip] = geo }
        }
    }

    /// Whether the tunnel is actually carrying this app's traffic.
    ///
    /// The engine's own answer, not `report.tunnel != nil`: an interface can
    /// exist because another WireGuard client made it, or because `wg-quick`
    /// left it behind. Only the route state can say whether anything is being
    /// intercepted.
    ///
    /// Cached, refreshed with the local report off the main thread. The live
    /// answer spawns `ifconfig`, and `Process.waitUntilExit` spins the main run
    /// loop; read from a view body (badge, status line, card rows) that nested
    /// run loop re-entered SwiftUI's layout mid-update and aborted the app
    /// with an AttributeGraph precondition failure on launch.
    @Published var tunnelCarriesTraffic = false

    /// The tunnel the coordinator drives, kept for the off-main probe above.
    private var tunnelControl: TunnelControl = NoTunnel()

    /// Tunnel mode is selected but the report says the tunnel stopped working.
    /// The status line says it; `noticeEvents` also posts a notification.
    var tunnelLost: Bool {
        TunnelLoss.isLost(runMode: runMode, report: report,
                          settling: busy || (settlingUntil.map { Date() < $0 } ?? false))
    }

    var badgeColor: Color {
        // DPI mode opens no routes and has no tunnel, so every tunnel-shaped
        // check below would call it red. Its colour comes from the proxy: green
        // only when the listener is actually up.
        if runMode == .dpi {
            return dpi.running ? Palette.success : Palette.warning
        }
        // Direct is not a failure. Nothing is intercepting because that is what
        // the user chose, so the dot is dim; red is reserved for "something is
        // running and broken", which is the only state that asks for a click.
        if runMode == .direct {
            guard report != nil else { return Palette.warning }
            // A tunnel left up by a previous session is still interception and
            // still needs to be readable, even though this session is not
            // driving it. Mere interface presence is not enough: an idle utun
            // from another client intercepts nothing.
            if tunnelCarriesTraffic { return Palette.warning }
            return Palette.secondary
        }
        guard let r = report else { return Palette.danger }
        // A report that could not even enumerate interfaces is not evidence of
        // a down tunnel. Amber ("I cannot tell yet") is the honest colour; red
        // would claim a measurement we do not have.
        if r.health.code == .unknown { return Palette.warning }
        guard r.tunnel != nil else { return Palette.danger }
        let activeRoutes = r.routes.filter(\.present).count
        let healthy = r.health.ok
        if mode != "off" && activeRoutes > 0 && healthy { return Palette.success }
        if mode == "off" { return Palette.warning }
        if activeRoutes == 0 { return Palette.danger }
        return Palette.warning
    }

    var statusLine: String {
        // DPI mode: the honest line is the counters and the port. There is no
        // handshake to age and no route to lose, so borrowing the tunnel's
        // sentences would describe something that is not running.
        if runMode == .dpi {
            guard dpi.running else { return l.t("dpi_off_state") }
            return dpi.summary(open: l.t("dpi_open"),
                               split: l.t("dpi_split"),
                               passthrough: l.t("dpi_passthrough"),
                               refused: l.t("dpi_refused"),
                               off: l.t("dpi_off_state"))
        }
        guard let r = report else { return l.t("checking") }
        // Direct, and nothing is intercepting: the honest line is the one the
        // user's own click produced. Claiming "checking" forever would make the
        // default state look broken, and claiming "tunnel down" would be a
        // measurement we never took.
        if runMode == .direct {
            if let iface = r.tunnel, tunnelCarriesTraffic {
                // A tunnel this app set up is up, but this session is not
                // driving it. Say both facts: the tunnel exists, and DPI is off.
                return "\(l.t("direct_tunnel_present")) · \(iface)"
            }
            return "\(l.t("mode_direct")) · \(l.t("off_state"))"
        }
        // Before the first privileged reply, or if the helper is missing, the
        // tunnel state is genuinely unknown. Saying "tunnel down" is a claim
        // the app cannot support, and it is the single most alarming thing this
        // line can say.
        if tunnelLost { return l.t(killSwitchActive ? "tunnel_lost_blocked" : "tunnel_lost") }
        if r.health.code == .unknown { return l.t("checking") }
        guard r.tunnel != nil else { return l.t("down") }
        if mode == "off" { return l.t("off_state") }
        let activeRoutes = r.routes.filter(\.present).count
        if activeRoutes == 0 { return l.t("routes_lost") }
        if r.health.ok {
            let age = humanAge(r.handshakeAgeS ?? r.health.ageS)
            return "\(l.t("up")) · \(l.t("f_handshake")) \(age)"
        }
        return l.t("unhealthy")
    }

    func humanAge(_ sec: Int?) -> String {
        guard let sec else { return l.t("never") }
        if sec < 60 { return l.t("s", ["n": "\(sec)"]) }
        if sec < 3600 { return l.t("m", ["n": "\(sec / 60)"]) }
        return l.t("h", ["n": "\(sec / 3600)"])
    }

    func bytes(_ n: Int?) -> String {
        var v = Double(n ?? 0)
        for unit in ["B", "KB", "MB", "GB"] {
            if v < 1024 { return unit == "B" ? "\(Int(v)) B" : String(format: "%.1f %@", v, unit) }
            v /= 1024
        }
        return String(format: "%.1f TB", v)
    }
}

// MARK: - Small views

/// A surface for a group of rows: card fill, 1 px separator edge.
struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1))
    }
}

/// A small control: raised fill, 1 px separator edge, dimmed when disabled.
struct Chip: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .background(Palette.raised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// The one accent-filled button: lighter on hover, flat grey while disabled.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Palette.accentText : Palette.secondary)
                .background(isEnabled ? Palette.accent : Palette.raised)
                .overlay(Color.white.opacity(isEnabled && hovering ? 0.08 : 0))
                .overlay(Color.black.opacity(configuration.isPressed ? 0.12 : 0))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Crossfades a status value when it changes: digits roll on macOS 14 and
/// later, plain opacity on macOS 13 and under Reduce Motion.
struct ValueChange: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 14, *), !reduceMotion {
                content.contentTransition(.numericText())
            } else {
                content.contentTransition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: value)
    }
}

/// The header's status dot. Breathes while something is in progress; under
/// Reduce Motion it only dims, it does not shrink. Colour is not the only cue:
/// it is a hollow ring while Menfez is off, and VoiceOver reads the mode.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    var on = true
    var label = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Group {
            if on { Circle().fill(color) }
            else { Circle().strokeBorder(color, lineWidth: 2) }
        }
            .opacity(dimmed ? 0.4 : 1)
            .scaleEffect(dimmed && !reduceMotion ? 0.8 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                               : .easeInOut(duration: 0.2),
                       value: dimmed)
            .onAppear { dimmed = pulsing }
            .onChange(of: pulsing) { dimmed = $0 }
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

struct HoverHighlight: ViewModifier {
    @State private var inside = false
    let base: Color
    var hover: Color = Palette.separator

    func body(content: Content) -> some View {
        content
            .background(inside ? hover : base)
            .onHover { inside = $0 }
            .animation(.easeOut(duration: 0.12), value: inside)
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var m: Model

    /// Every sheet in the window, behind one value.
    ///
    /// WHAT WAS HERE BEFORE
    /// Four independent states (`showServers`, `showDNS`, `detail`, `showHelp`),
    /// four `.sheet` modifiers and two ways to close them. Two of the Close
    /// buttons called `NSApp.keyWindow?.sheetParent?.endSheet(...)` instead of
    /// clearing the flag, so the AppKit sheet went away while the SwiftUI state
    /// still said "presented" — and the next body evaluation, which this window
    /// performs every two seconds, presented it again. See `SheetRouter` for the
    /// full explanation and `PresentationTests` for the proof.
    @State private var router = SheetRouter<SheetRoute>()

    /// Servers sheet: the profile being renamed, its field, and the refusal
    /// shown under it; the profile waiting for the delete confirmation.
    @State private var editing: String?
    @State private var editName = ""
    @State private var editError: String?
    @State private var pendingDelete: Profile?

    /// Follow the system, or force dark or light. See `Appearance`.
    @AppStorage(Appearance.key) private var appearanceRaw = Appearance.system.rawValue
    /// Last release whose "What's new" the user opened; the header dot shows until it is the current one.
    @AppStorage("whatsNewSeen") private var whatsNewSeen = ""
    @AppStorage(DoHProvider.defaultsKey) private var dohRaw = DoHProvider.cloudflare.rawValue
    @AppStorage(DNSManager.tunnelDNSKey) private var dnsViaTunnel = true
    private var appearance: Appearance { Appearance(rawValue: appearanceRaw) ?? .system }

    /// Shared with the menu-bar extra, so both list and call the same modes.
    private let modes = MenuBarModes.order.map(MenuBarModes.path)

    @Namespace private var tabSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    /// How pickers, notes and the DPI panel come and go: fade and drop in,
    /// or only fade under Reduce Motion.
    private var reveal: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    var body: some View {
        // One column, top to bottom, no scrolling. The column has a fixed
        // width and its natural height, and the window (`.contentSize`)
        // follows it, so showing or hiding the pickers resizes the window
        // instead of leaving a gap or a scroll bar. Nothing here sets a frame
        // on the window itself.
        VStack(alignment: .leading, spacing: Space.m) {
            headerBlock
            controls
            details
            footer
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .padding(.bottom, Space.m)
        .frame(width: PageLayout.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Mode changes show and hide blocks; animating them also animates
        // the window height, which follows the content.
        .animation(.easeInOut(duration: 0.22), value: m.runMode)
        .animation(.easeInOut(duration: 0.22), value: m.profiles.isEmpty)
        .background(Palette.bg)
        .preferredColorScheme(appearance.scheme)
        .onAppear {
            NSApp.appearance = appearance.nsAppearance
            // A notification click reopens this window even after it was closed.
            Notifier.shared.openMain = { [openWindow] in openWindow(id: MenuBarContent.mainWindowID) }
            // First run only; an upgrading user is marked as having seen it.
            if Onboarding.shouldShow() {
                DispatchQueue.main.async { show(.onboarding) }
            } else {
                Onboarding.markSeen()
            }
        }
        .onChange(of: appearanceRaw) { _ in NSApp.appearance = appearance.nsAppearance }
        .onChange(of: m.serverRequests) { _ in show(.servers) }
        .onChange(of: m.serverSheetCloses) { _ in close(.servers) }
        .onChange(of: m.siteTestRequests) { _ in show(.siteTest) }
        .alert(m.l.t("discord_restart_title"),
               isPresented: Binding(get: { m.discordRestartPID != nil },
                                    set: { shown in
                                        // The buttons do the work (Escape runs "Not now");
                                        // this only clears, outside the view update.
                                        if !shown { DispatchQueue.main.async { m.discordRestartPID = nil } }
                                    })) {
            Button(m.l.t("discord_restart_yes")) {
                if let pid = m.discordRestartPID { m.restartDiscord(pid: pid) }
            }
            Button(m.l.t("discord_restart_no"), role: .cancel) { m.declineDiscordRestart() }
        } message: {
            Text(m.l.t("discord_restart_body"))
        }
        .sheet(item: sheetBinding) { sheet in
            // Built here, not in a stored property, so it cannot capture a stale
            // `m.lang` from before the sheet was presented.
            sheetView(sheet.route)
        }
    }

    /// The binding `.sheet(item:)` needs.
    ///
    /// Reads come straight from the router. A write can only ever be nil —
    /// SwiftUI saying "I ended this sheet myself" (Escape, the window's close
    /// button) — and goes through `syncFromSystem`, which clears the route and
    /// has no way to set one. That is the fix in one line: no code path turns a
    /// dismissal into a presentation.
    private var sheetBinding: Binding<PresentedSheet<SheetRoute>?> {
        Binding(
            get: { router.item },
            set: { router.syncFromSystem($0?.route) }
        )
    }

    /// Open a panel. A no-op while one is already up, which is what stops a
    /// queued click on the button behind the modal from replacing what the user
    /// is reading.
    private func show(_ route: SheetRoute) {
        router.present(route)
    }

    private func close(_ route: SheetRoute) {
        router.dismiss(route)
    }

    /// Close one panel and open another once it has gone; the router refuses
    /// a second sheet while one is up.
    private func swap(_ from: SheetRoute, for to: SheetRoute) {
        close(from)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { show(to) }
    }

    /// The panel for a route.
    ///
    /// Every branch closes through `close(_:)`. None of them reaches for
    /// `NSApp.keyWindow` or `endSheet`, which is what made the old Close buttons
    /// disagree with the state they were bound to.
    @ViewBuilder
    private func sheetView(_ route: SheetRoute) -> some View {
        switch route {
        case .servers:
            serverSheet
                // The list is read from disk on open rather than on the fast
                // tick: opening the picker is the only time anyone reads it,
                // and the country lookup behind an unnamed profile is a network
                // request the timer must not make on the user's behalf.
                .onAppear { m.loadProfiles() }
                // Closed without a pick: a later import must not start the tunnel.
                .onDisappear { m.pendingTunnelStart = false }
        case .dns:
            dnsSheet
                // The resolver sheet costs ~21 `dig` queries. It used to be
                // fetched on every 5-second tick, which is why opening it felt
                // instant; it is now fetched when it is opened, which is the
                // only time anyone reads it.
                .onAppear { m.refreshDNS() }
        case .help:
            // The helper path is passed in so the setup command names this
            // bundle's own binary rather than a path from documentation.
            HelpSheet(lang: m.lang, helperPath: m.backend.bundledHelper,
                      installRunning: m.tunnelInstall.isRunning,
                      installMessage: m.tunnelInstallMessage,
                      onInstall: m.canRunTunnelInstaller ? { m.runTunnelInstaller(.install) } : nil,
                      installed: m.capabilities.tunnelAvailable,
                      onRemove: m.canRunTunnelInstaller ? { m.runTunnelInstaller(.remove) } : nil,
                      removeBlockedReason: m.runMode == .tunnel ? m.l.t("tunnel_remove_leave_first") : nil,
                      onImport: { close(.help); importConfig() },
                      onSiteTest: { swap(.help, for: .siteTest) },
                      onGuide: { swap(.help, for: .onboarding) },
                      onExportLog: { m.exportDebugLog() }) { close(.help) }
        case .about:
            AboutSheet(lang: m.lang) { close(.about) }
        case .whatsNew:
            WhatsNewSheet(lang: m.lang) { close(.whatsNew) }
        case .onboarding:
            OnboardingSheet(lang: m.lang,
                            showTunnelSetup: !m.capabilities.tunnelAvailable && m.canRunTunnelInstaller,
                            installRunning: m.tunnelInstall.isRunning,
                            installMessage: m.tunnelInstallMessage,
                            onInstall: { m.runTunnelInstaller(.install) },
                            onStartDPI: {
                                close(.onboarding)
                                Notifier.shared.requestPermission()
                                m.enableDPIAndLaunchDiscord()
                            },
                            onDone: {
                                close(.onboarding)
                                Notifier.shared.requestPermission()
                            },
                            onSkip: { close(.onboarding) })
                // However it closed (button, Escape), it does not come back by itself.
                .onDisappear { Onboarding.markSeen() }
        case .leakTest:
            LeakTestSheet(lang: m.lang, onRun: { await m.runLeakTest() }) { close(.leakTest) }
        case .sites:
            SitesSheet(m: m) { close(.sites) }
        case .siteTest:
            SiteTestSheet(lang: m.lang,
                          tunnelOnlyDiscord: m.runMode == .tunnel && !m.tunnelCarriesEverything,
                          onRun: { await m.runSiteTest($0) }) { close(.siteTest) }
        case .detail(let d):
            DetailView(sheet: d, lang: m.lang) { close(.detail(d)) }
        }
    }

    // --- page layout -----------------------------------------------------

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            // Starts where the title starts, past the status dot.
            statusText
                .padding(.leading, HeaderMetrics.dot + HeaderMetrics.gap + 4)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if m.helperOutdated { helperUpdateRow }
            if m.tunnelLost && m.killSwitchActive { blockedRow }
            primaryAction
            modeBar
            // The server picker only configures the tunnel; in DPI and direct
            // mode there is no tunnel to point anywhere, so it would be a dead
            // control. The detail card stays, because most of its rows describe
            // the machine rather than the tunnel and are true in every mode.
            // With no profile yet it shows anyway: it is the way to the import.
            if TunnelRecovery.showsServerRow(inTunnel: m.runMode == .tunnel, routeMode: m.mode,
                                             carrying: m.tunnelCarriesTraffic) {
                pickers.transition(reveal)
                if m.runMode == .tunnel {
                    scopeControl.transition(reveal)
                    tunnelSafetyRow.transition(reveal)
                }
            } else if m.runMode != .direct {
                // Direct mode: the DNS row in the card opens the same sheet.
                dnsButton(labelled: true)
            }
            // Setup state of the optional tunnel; moot while it is running.
            if m.runMode != .tunnel {
                tunnelRow.transition(reveal)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            card
            if m.dpiOn {
                dpiPanel.transition(reveal)
            }
        }
    }

    // --- header ----------------------------------------------------------

    /// Title block, status dot, and the four controls, on one vertical centre.
    ///
    /// THE BUG THIS FIXES
    /// The row used `.top` alignment, so every control's *box* was pinned to the
    /// top of the title. A 23 pt language chip whose top is level with the top of
    /// a 31 pt line of type sits about 4.5 pt high relative to the type's optical
    /// centre — "the language button looks a bit too high". The eye compares
    /// centres, not top edges.
    ///
    /// THE GEOMETRY, measured from the top of the title's line box:
    ///   * every element is a `HeaderMetrics.line` = 32 pt box, the 26 pt bold
    ///     font's line height (30.62) rounded up to a whole point;
    ///   * inside that box the content is centred, so the shared centre sits at
    ///     16 pt — the middle of the title's capitals, 25.14 - 18.32/2 = 15.98;
    ///   * the status dot (15 pt), the language chip (23 pt), and the three icon
    ///     buttons (26 pt) are all centred within their 32 pt box, so their
    ///     centres coincide instead of their tops;
    ///   * the row itself is `.top`-aligned, because the title block is 46 pt
    ///     tall (name + tagline) and `.center` would centre the 32 pt boxes
    ///     against *that* height instead, putting them 7 pt low.
    ///
    /// WHAT THIS DELIBERATELY IS NOT
    /// The tagline does not join the centre line. It hangs under the name, so
    /// the block reads as one unit and the controls align with the name, which is
    /// the biggest thing in the row. The status dot sits beside the name for the
    /// same reason: it marks the app, not the paragraph.
    private var header: some View {
        HStack(alignment: .top, spacing: HeaderMetrics.gap) {
            StatusDot(color: m.badgeColor, pulsing: m.busy || m.probing,
                      on: m.runMode != .direct,
                      label: m.l.t(MenuBarModes.labelKey(m.runMode)))
                .frame(width: HeaderMetrics.dot, height: HeaderMetrics.dot)
                // The dot is a fixed 32 pt box with the circle centred in it, so
                // its centre lands on the shared line and not 8 pt above it (the
                // old `.padding(.top, 8)` was an eyeballed approximation of this).
                .frame(width: HeaderMetrics.dot, height: HeaderMetrics.line)

            VStack(alignment: .leading, spacing: 1) {
                // New York, the system serif: a wordmark, not a label. Same
                // 26 pt and cap height as the old SF bold, so the header
                // geometry in `HeaderLayout` holds.
                // ".app" is the domain (menfez.app): small and muted on the
                // same baseline, so the wordmark still reads "Menfez".
                (Text(m.l.t("app"))
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                 + Text(".app")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundColor(Palette.secondary))
                    .tracking(-0.2)
                    .foregroundStyle(Palette.text)
                    .accessibilityLabel(m.l.t("app"))
                    .frame(height: HeaderMetrics.line, alignment: .center)
                Text(m.l.t("tagline"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.leading, 4)

            Spacer(minLength: 8)

            // One cluster, one height. Giving the HStack a 32 pt frame is what
            // makes `.center` mean "the row's centre" rather than "the centre of
            // whichever child happens to be tallest".
            HStack(alignment: .center, spacing: HeaderMetrics.iconGap) {
                Button {
                    m.setLang(m.lang == .tr ? .en : .tr)
                } label: {
                    HStack(spacing: 5) {
                        Text(m.lang.flag)
                        Text(m.lang.label)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(Palette.text)
                .help(m.lang.label)

                HeaderIcon(symbol: appearance.symbol, help: appearanceHelp) {
                    appearanceRaw = appearance.next.rawValue
                }

                HeaderIcon(symbol: "sparkles", help: m.l.t("whatsnew_hint"),
                           badge: whatsNewSeen != Changelog.entries.first?.version) {
                    whatsNewSeen = Changelog.entries.first?.version ?? ""
                    show(.whatsNew)
                }

                HeaderIcon(symbol: "info.circle", help: m.l.t("about_hint")) {
                    show(.about)
                }

                HeaderIcon(symbol: "questionmark.circle", help: m.l.t("help_hint")) {
                    show(.help)
                }

                // Optional, and quiet. Hidden rather than disabled when the URL
                // is missing: a donation button that does nothing is worse than
                // none. `Palette.secondary` keeps it one step dimmer than the two
                // documentation icons, so it reads as an aside.
                if let coffee = Links.openable(Links.support) {
                    HeaderIcon(symbol: "cup.and.saucer", help: m.l.t("donate_hint"),
                               tint: Palette.secondary) {
                        NSWorkspace.shared.open(coffee)
                    }
                }
            }
            .frame(height: HeaderMetrics.line)
        }
    }

    /// "Görünüm: Sistem → Koyu": the current choice and what a click picks.
    private var appearanceHelp: String {
        "\(m.l.t("appearance")): \(m.l.t("app_" + appearance.rawValue)) → \(m.l.t("app_" + appearance.next.rawValue))"
    }

    private var statusText: some View {
        Text(m.statusLine)
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            .modifier(ValueChange(value: m.statusLine))
            .foregroundStyle(m.badgeColor == Palette.danger ? Palette.danger :
                             (m.badgeColor == Palette.warning ? Palette.warning : Palette.secondary))
    }

    // --- primary action --------------------------------------------------

    /// The first thing a new user sees, and the whole free tier in one click.
    ///
    /// "Enable Discord" starts the loopback proxy and launches Discord pointed
    /// at it. Neither step needs a password: the proxy is a listener inside this
    /// process, and the launch is `open --args --proxy-server=…`. That is the
    /// property this layout exists to make obvious — the previous version put
    /// the tunnel's mode buttons first, so a stranger's first click went to a
    /// helper they had never installed.
    private var primaryAction: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                m.enableDPIAndLaunchDiscord()
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: m.dpiOn ? "bolt.horizontal.fill" : "bolt.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.dpiOn
                             ? m.l.t("dpi_launch_again")
                             : m.l.t("dpi_enable_discord"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(m.dpiOn
                             ? m.l.t("dpi_launch_again_hint")
                             // The click switches modes: in tunnel mode it
                             // tears the tunnel down first, so say so.
                             : m.l.t(m.runMode == .tunnel ? "dpi_enable_from_tunnel_hint"
                                                          : "dpi_enable_hint"))
                            .font(.system(size: 11))
                            .opacity(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(m.busy)
            .help(m.l.t("dpi_no_root_note"))

            // The rootless promise, stated where the click happens rather than
            // buried in Help. It is the reason a stranger can use this app.
            HStack(alignment: .firstTextBaseline, spacing: Space.s - 2) {
                Image(systemName: "lock.open")
                    .font(.system(size: 10))
                Text(m.l.t("dpi_no_root_note"))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.secondary)
        }
    }

    // --- mode chips ------------------------------------------------------

    /// The three states, as a segmented control.
    ///
    /// `direct` is the panic button and is always enabled. `dpi` is always
    /// enabled. `tunnel` is enabled only when the capability probe found a
    /// working helper — disabled with the reason attached rather than hidden,
    /// so a user who wonders why it is off finds out by hovering instead of
    /// clicking into an error.
    private var modeBar: some View {
        HStack(spacing: Space.xs) {
            ForEach(modes, id: \.self) { path in
                let labelKey = "mode_" + path
                let active = m.runMode.rawValue == path
                let available = path == "tunnel" ? m.capabilities.tunnelAvailable : true
                Button {
                    m.setMode(path)
                } label: {
                    HStack(spacing: 4) {
                        if path == "tunnel" && !available {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                        }
                        Text(m.l.t(labelKey))
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                            .fill(Palette.accent.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                                .strokeBorder(Palette.accent, lineWidth: 1))
                            // One shared id slides the highlight between tabs.
                            // Under Reduce Motion each tab has its own id, so
                            // the highlight fades out and in instead.
                            .matchedGeometryEffect(id: reduceMotion ? "tab-\(path)" : "tab",
                                                   in: tabSelection)
                    }
                }
                .foregroundStyle(active ? Palette.text : Palette.secondary)
                // Visibly unavailable, not merely grey: the lock and the fade
                // together say "not now", and the tooltip says why.
                .opacity(available ? 1 : 0.45)
                .disabled(m.busy || !available)
                .help(path == "tunnel" && !available
                      ? m.tunnelReason
                      : m.l.t(labelKey + "_hint"))
            }
        }
        .padding(Space.xs - 1)
        .modifier(Card())
    }

    /// Discord only / Discord + sites / Whole internet, with one line on what
    /// the choice means. Drawn like the mode bar, one size down, so it reads
    /// as part of Tunnel.
    private var scopeControl: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                ForEach(TunnelScope.Choice.allCases, id: \.self) { scope in
                    let active = m.scopeChoice == scope
                    let available = scope != .sites || m.sitesAvailable
                    Button {
                        m.setTunnelScope(scope)
                    } label: {
                        Text(m.l.t("m_" + scope.rawValue))
                            .font(.system(size: 11, weight: active ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.xs + 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                                .fill(Palette.accent.opacity(0.14))
                                .overlay(RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                                    .strokeBorder(Palette.accent, lineWidth: 1))
                        }
                    }
                    .foregroundStyle(active ? Palette.text : Palette.secondary)
                    .opacity(available ? 1 : 0.45)
                    .disabled(m.busy || !available)
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .help(m.l.t(available ? "scope_" + scope.rawValue + "_hint" : "sites_needs_update"))
                }
            }
            .padding(Space.xs - 1)
            .modifier(Card())
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(m.l.t("scope_" + m.scopeChoice.rawValue + "_hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if m.scopeChoice == .sites {
                    Spacer(minLength: 4)
                    Button { show(.sites) } label: {
                        Text(m.l.t("sites_edit", ["what": String(m.sites.count)]))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, Space.s + 2)
                            .padding(.vertical, Space.xs + 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(Chip())
                    .foregroundStyle(Palette.accent)
                    .fixedSize()
                }
            }
        }
    }

    /// Kill switch and leak test, under the scope picker in Tunnel mode.
    private var tunnelSafetyRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                if m.killSwitchAvailable {
                    Toggle(isOn: Binding(get: { m.killSwitchActive },
                                         set: { m.setKillSwitch($0) })) {
                        Text(m.l.t("ks_toggle")).font(.system(size: 11.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(m.busy)
                }
                Spacer(minLength: 4)
                Button { show(.leakTest) } label: {
                    Text(m.l.t("leak_open"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, Space.s + 2)
                        .padding(.vertical, Space.xs + 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(Palette.accent)
                .disabled(!m.tunnelCarriesTraffic)
            }
            if m.killSwitchAvailable {
                Text(m.l.t("ks_hint_" + m.scopeChoice.rawValue))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The tunnel is down and the kill switch is holding traffic back.
    private var blockedRow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
                Text(m.l.t(m.scopeChoice == .all ? "ks_blocked" : "ks_blocked_" + m.scopeChoice.rawValue))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                ForEach([("ks_reconnect", true), ("ks_unblock", false)], id: \.0) { key, reconnect in
                    Button {
                        if reconnect { m.setMode("tunnel") } else { m.unblock() }
                    } label: {
                        Text(m.l.t(key))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, Space.s + 2)
                            .padding(.vertical, Space.xs + 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(Chip())
                    .foregroundStyle(reconnect ? Palette.accent : Palette.text)
                    .disabled(m.busy)
                }
            }
        }
        .padding(Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.danger.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// The installed helper is older than this app's. One line and a button
    /// that reruns the setup (macOS asks for the password).
    private var helperUpdateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Palette.warning)
            Text(m.tunnelInstallMessage ?? m.l.t("helper_outdated"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                m.runTunnelInstaller(.install)
            } label: {
                HStack(spacing: 5) {
                    if m.tunnelInstall.isRunning { ProgressView().controlSize(.mini) }
                    Text(m.l.t("helper_update")).font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, Space.s + 2)
                .padding(.vertical, Space.xs + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Chip())
            .foregroundStyle(Palette.accent)
            .disabled(m.tunnelInstall.isRunning)
        }
    }

    // --- secondary tunnel row --------------------------------------------

    /// The optional extra, stated once and quietly.
    ///
    /// A missing helper is not an error and must not look like one: nothing
    /// broke, the user simply has not installed the optional piece. When the
    /// helper is usable this row is a one-liner pointing at the tunnel chip;
    /// when it is not, it explains the one-time setup and opens Help, where the
    /// command is copyable. No modal, no red.
    private var tunnelRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: m.capabilities.tunnelAvailable ? "shield.lefthalf.filled" : "lock")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
            if m.capabilities.tunnelAvailable {
                Text(m.l.t(Profile.tunnelReadyKey(m.profiles)))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The installer's progress or result replaces the reason while
                // there is one: it is the newer news.
                Text(m.tunnelInstallMessage ?? m.tunnelReason)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !m.capabilities.tunnelAvailable {
                Button {
                    // Without a bundled installer (a `swift run`), Help still
                    // has the Terminal route.
                    if m.canRunTunnelInstaller { m.runTunnelInstaller(.install) } else { show(.help) }
                } label: {
                    HStack(spacing: 5) {
                        if m.tunnelInstall.isRunning {
                            ProgressView().controlSize(.mini)
                        }
                        Text(m.l.t(m.canRunTunnelInstaller ? "tunnel_install" : "tunnel_setup"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, Space.s + 2)
                    .padding(.vertical, Space.xs + 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(Palette.accent)
                .disabled(m.tunnelInstall.isRunning)
            }
        }
    }

    // --- server + dns pickers -------------------------------------------

    /// Two pickers that share the row, with the growing half given to the server
    /// name.
    ///
    /// The server label is the one that can be long (a provider's own naming), so
    /// it takes the extra width the window offers. The resolver half only ever
    /// holds an address: it is capped, which keeps it from looking like the more
    /// important of the two when the window is wide.
    private var pickers: some View {
        HStack(spacing: 6) {
            Button { show(.servers) } label: {
                HStack(spacing: 6) {
                    Text(m.l.t("pill_server"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize()
                    if let p = m.activeProfile {
                        if let flag = ProfileNaming.flag(p.country) {
                            Text(flag)
                        } else {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(Palette.secondary)
                        }
                        Text(p.display ?? Countries.name(p.country, lang: m.lang))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(Palette.secondary)
                        Text(m.l.t("servers"))
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Chip())
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)

            dnsButton(labelled: false)
        }
    }

    /// The resolver chip. On screen in every mode: the DNS sheet is also where
    /// the encrypted-DNS provider is picked, and DPI mode uses that.
    /// `labelled` adds the word "DNS" when the chip stands alone; beside the
    /// server chip its width is capped and the icon is enough.
    private func dnsButton(labelled: Bool) -> some View {
        Button { show(.dns) } label: {
            HStack(spacing: 6) {
                // The "DNS:" prefix names the chip; the icon would only cost width.
                Text("DNS:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize()
                Text(m.dns?.current.first ?? m.l.t("automatic"))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(Chip())
        .foregroundStyle(Palette.text)
        // About 40/60 in the 360 pt side column: the resolver gets 156 pt (room for "Oto (DHCP)") and
        // the server label, the long one, takes the rest and all the growth.
        .frame(minWidth: WidthPolicy.dnsPickerMin,
               idealWidth: labelled ? nil : WidthPolicy.dnsPickerIdeal,
               maxWidth: labelled ? nil : WidthPolicy.dnsPickerMax,
               alignment: .leading)
        .fixedSize(horizontal: labelled, vertical: false)
    }

    // --- detail card -----------------------------------------------------

    private var rows: [(String, String, String, Color?, String?)] {
        guard let r = m.report else { return [] }
        // Tunnel mode: the server's address and geo (see CardIdentity).
        let identity = m.cardIdentity
        let geo = identity.geo
        let activeRoutes = r.routes.filter(\.present).count
        let totalRoutes = r.routes.count
        // The four tunnel-shaped rows describe interception. Show them when a
        // tunnel is actually carrying traffic, or when the user just asked for
        // tunnel mode (routes take a moment to appear and an empty card in that
        // window would look like a failure). A bare utun from another client is
        // not interception, so it does not earn four "none/never" rows.
        // The hybrid updates tunnel is not a mode the user chose: it gets a
        // note in the DPI card, not these rows.
        let inTunnel = m.runMode == .tunnel
        let tunnelShown = TunnelRecovery.showsTunnelDetails(inTunnel: inTunnel, routeMode: m.mode,
                                                            carrying: m.tunnelCarriesTraffic)

        var out: [(String, String, String, Color?, String?)] = []
        out.append(("globe", m.l.t("f_egress"), identity.ip ?? "—", nil, "ip"))
        // `joined` on an empty list is "", not nil, so a missing geolocation
        // used to render as a blank cell that looks like a layout fault. Every
        // other missing measurement in this card is a dash.
        let place = [geo?.city, geo?.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        out.append(("mappin.and.ellipse", m.l.t("f_where"), place.isEmpty ? "—" : place, nil, "ip"))
        out.append(("building.2", m.l.t("f_isp"), geo?.ispShort ?? geo?.org ?? "—", nil, nil))
        if TunnelRecovery.showsServerRow(inTunnel: inTunnel, routeMode: m.mode,
                                         carrying: m.tunnelCarriesTraffic) {
            if let p = m.activeProfile {
                out.append(("shield.lefthalf.filled", m.l.t("f_server"),
                            "\(ProfileNaming.flag(p.country) ?? "") \(p.display ?? Countries.name(p.country, lang: m.lang))",
                            nil, nil))
            } else if m.tunnelCarriesTraffic {
                // A tunnel is up but no file matches it: name it from the live
                // endpoint, the source of the rows above, never "none".
                let place = inTunnel
                    ? [geo?.city, geo?.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                    : ""
                let flag = inTunnel ? ProfileNaming.flag(geo?.country).map { $0 + " " } ?? "" : ""
                out.append(("shield.lefthalf.filled", m.l.t("f_server"),
                            "\(flag)\(place.isEmpty ? (r.endpoint ?? "—") : place) · \(m.l.t("srv_not_in_list"))",
                            Palette.warning, nil))
            } else {
                out.append(("shield.lefthalf.filled", m.l.t("f_server"), m.l.t("none"), Palette.secondary, nil))
            }
        }
        out.append(("magnifyingglass", m.l.t("f_dns"),
                    r.dns.first ?? m.l.t("auto"),
                    r.dns.isEmpty ? Palette.secondary : nil, "dns"))
        // Everything below describes the tunnel. With no tunnel up they would
        // all read "none/never" while the proxy above is doing its job.
        if tunnelShown {
            out.append(("slider.horizontal.3", m.l.t("f_mode"), m.l.t("m_" + m.mode),
                        m.mode == "off" ? Palette.secondary : Palette.success, nil))
            out.append(("arrow.triangle.branch", m.l.t("f_routes"),
                        totalRoutes == 0 ? m.l.t("none")
                            : m.l.t("active_n", ["n": "\(activeRoutes)", "total": "\(totalRoutes)"]),
                        totalRoutes > 0 && activeRoutes == totalRoutes ? Palette.success
                            : (totalRoutes == 0 ? Palette.secondary : Palette.danger),
                        "routes"))
            out.append(("arrow.left.arrow.right", m.l.t("f_handshake"), m.humanAge(r.handshakeAgeS),
                        (r.handshakeAgeS ?? 9999) < 180 ? Palette.success : Palette.warning,
                        "tunnel"))
            let tr = r.transfer
            // A nil transfer is a probe that could not run, not a tunnel that
            // moved zero bytes. It renders as a dash, the same way every other
            // missing measurement does.
            let transferText: String
            if let tr {
                transferText = "↓ \(m.bytes(tr.rx))  ↑ \(m.bytes(tr.tx))"
            } else {
                transferText = "—"
            }
            out.append(("arrow.up.arrow.down", m.l.t("f_transfer"), transferText, nil, nil))
        }

        let code = r.discord.code
        let ms = r.discord.ms
        let discordText: String
        let discordColor: Color
        if code == 200 {
            discordText = ms.map { m.l.t("ok_ms", ["ms": "\($0)"]) } ?? m.l.t("ok")
            discordColor = Palette.success
        } else if code != 0 {
            discordText = m.l.t("http", ["code": "\(code)"])
            discordColor = Palette.warning
        } else if r.discord.failure == nil {
            // Not measured yet on this path (launch, or just after a switch).
            discordText = "—"
            discordColor = Palette.secondary
        } else {
            discordText = m.l.t((r.discord.failure ?? .blocked).labelKey)
            discordColor = Palette.danger
        }
        out.append(("bubble.left.and.bubble.right", m.l.t("f_discord"), discordText, discordColor, "discord"))
        return out
    }

    private var card: some View {
        let list = rows
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, row in
                let (symbol, label, value, color, target) = row
                HStack(spacing: Space.m) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 18)
                    Text(label).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text(value)
                        .font(.system(size: 13, weight: value == "—" ? .regular : .medium))
                        .monospacedDigit()
                        // A dash is an absent measurement, not a value: it
                        // gets the quiet colour whatever the row's tone.
                        .foregroundStyle(value == "—" ? Palette.secondary : (color ?? Palette.text))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // The value is the measurement; the label is a caption
                        // the user already knows. When the window is at its
                        // narrowest the label may shorten, never the number.
                        .layoutPriority(1)
                        .modifier(ValueChange(value: value))
                    if target != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s - 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    // The DNS row is the way to the resolver settings in every
                    // mode (direct mode has no separate DNS chip).
                    if target == "dns" { show(.dns) }
                    else if let target { show(.detail(detailSheetData(target))) }
                }
                .help(target.map { m.l.t("det_" + $0) } ?? "")
                if index < list.count - 1 {
                    Rectangle().fill(Palette.separator).frame(height: 1)
                        .padding(.leading, Space.l + 18 + Space.m)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .modifier(Card())
    }

    // --- DPI panel -------------------------------------------------------

    /// The free tier's whole visible surface: port, counters, honesty, launch.
    ///
    /// Shown only in DPI mode. Everything here is either a number the engine
    /// counted or a sentence the probe measured; there is no "on/healthy" light
    /// that could claim health without a measurement.
    private var dpiPanel: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                Text(m.l.t("dpi_title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                // The counters are the proof the proxy is doing something. They
                // are shown even at zero, because "0 split" while Discord is
                // connected is information: nothing has gone through the proxy.
                Text(m.dpi.running ? "127.0.0.1:\(m.dpi.port ?? 0)" : m.l.t("dpi_off"))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(m.dpi.running ? Palette.success : Palette.secondary)
            }

            HStack(alignment: .bottom, spacing: Space.l) {
                counter("\(m.dpi.reframed)", m.l.t("dpi_split"), Palette.success)
                counter("\(m.dpi.passthrough)", m.l.t("dpi_passthrough"), Palette.secondary)
                counter("\(m.dpi.connections)", m.l.t("dpi_open"), Palette.accent)
                if m.dpi.rejected > 0 {
                    counter("\(m.dpi.rejected)", m.l.t("dpi_refused"), Palette.warning)
                }
                Spacer()
                Text(m.l.t("dpi_at", ["n": "\(m.dpi.splitAt)"]))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }

            // The probe's verdict is the only thing on this panel that says
            // whether the split is *needed*, and it exists only after the user
            // asked. Before that the panel says so rather than implying health.
            if let probe = m.probe {
                Text(m.l.verdict(probe.verdict))
                    .font(.system(size: 12))
                    .foregroundStyle(Self.probeColor(probe.verdict))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if TunnelRecovery.isUpdatesHybrid(routeMode: m.mode, carrying: m.tunnelCarriesTraffic) {
                Label(m.l.t("updates_tunnel_on"), systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.s) {
                Button {
                    m.launchDiscord()
                } label: {
                    Text(m.l.t("discord_launch"))
                        .font(.system(size: 12))
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s - 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(m.dpi.running ? Palette.text : Palette.secondary)
                .disabled(!m.dpi.running)
                .help(m.dpiMode?.discordAvailability.reason ?? "")

                Button {
                    m.runProbe()
                } label: {
                    HStack(spacing: 5) {
                        if m.probing { ProgressView().controlSize(.mini) }
                        Text(m.probing ? m.l.t("dpi_probing") : m.l.t("dpi_probe"))
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s - 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(Palette.text)
                .disabled(m.probing || !m.dpi.running)

                Button {
                    m.disableDPI()
                } label: {
                    Text(m.l.t("dpi_stop"))
                        .font(.system(size: 12))
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s - 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(Chip())
                .foregroundStyle(Palette.text)

                Spacer()
            }

            if m.discordSettingsHint {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(m.l.t("discord_settings_hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        Button(m.l.t("discord_settings_retry")) { m.retryDiscordSettings() }
                            .disabled(!m.dpi.running)
                        Button(m.l.t("close")) { m.dismissDiscordSettingsHint() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s - 2)
                    .foregroundStyle(Palette.text)
                }
            }

            // Said every time, not only on failure: the flag is read at launch,
            // so a running Discord is never covered no matter what the proxy does.
            Text(m.l.t("dpi_quit_first"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.l)
        .modifier(Card())
    }

    private func counter(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
        }
    }

    private static func probeColor(_ verdict: DPIProbeOutcome.Verdict) -> Color {
        switch verdict {
        case .working:     return Palette.success
        case .notNeeded:   return Palette.accent
        case .notHelping:  return Palette.danger
        case .dnsBlocked:  return Palette.warning
        case .proxyBroken: return Palette.danger
        case .proxyOff:    return Palette.warning
        }
    }

    // --- footer ----------------------------------------------------------

    /// Last action's outcome and Refresh, under a hairline, spanning the
    /// same width as the content above it.
    private var footer: some View {
        HStack(spacing: Space.m) {
            // Wraps rather than truncating: a failure sentence cut at "…" is
            // the part the user needed.
            Text(m.status.isEmpty ? m.lastUpdatedLine : m.status)
                .font(.system(size: 11))
                .foregroundStyle(m.status.isEmpty ? Palette.secondary : m.statusColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button {
                m.refresh()
            } label: {
                Label(m.l.t("refresh"), systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s - 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Chip())
            .foregroundStyle(Palette.text)
            .disabled(m.busy)
        }
        .padding(.top, Space.m)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 1)
        }
    }

    // --- sheets ----------------------------------------------------------

    // Internal, not private, so the DEBUG snapshot can draw it.
    var serverSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.l.t("servers"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.bottom, 10)

            if keychainOffer { keychainOfferRow }

            if m.profiles.isEmpty {
                Text(m.l.t("no_profiles"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 12)
                // Nobody ships a server with this app; say so where the list is empty.
                Text(m.l.t("byo_conf"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }

            ForEach(m.profiles) { p in
                if editing == p.name {
                    profileEditor(p)
                } else {
                    profileRow(p)
                }
            }

            Text(m.l.t("any_provider"))
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            // The quiet way back: after "Not now", or to undo a move.
            if !keychainOffer, let link = keychainLink {
                Button(m.l.t(link.key)) { m.moveKeys(toKeychain: link.toKeychain) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .disabled(m.busy)
                    .padding(.top, 4)
            }

            HStack(spacing: 6) {
                Button(m.l.t("import_conf")) { importConfig() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)

                Spacer()

                Button(m.l.t("close")) { close(.servers) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 400)
        .background(Palette.bg)
        .alert(pendingDelete.map { m.l.t("srv_delete_q", ["name": $0.name]) } ?? "",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { p in
            Button(m.l.t("srv_delete"), role: .destructive) {
                pendingDelete = nil
                m.deleteProfile(p)
            }
            Button(m.l.t("srv_cancel"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(m.l.t("srv_delete_body"))
        }
    }

    /// Some keys still sit in files and the offer was not turned down.
    private var keychainOffer: Bool {
        m.keychainAvailable && !m.keychainOfferDismissed && m.profiles.contains { $0.keychain != true }
    }

    /// "Move keys to Keychain" while any file holds its key, else "Write keys
    /// back" while any key is in the Keychain. Restoring works without the
    /// signed-build check, so a key is never stranded.
    private var keychainLink: (key: String, toKeychain: Bool)? {
        if m.keychainAvailable, m.profiles.contains(where: { $0.keychain != true }) {
            return ("kc_move_link", true)
        }
        return m.profiles.contains(where: { $0.keychain == true }) ? ("kc_restore", false) : nil
    }

    /// The one-time offer after the upgrade to 1.0.7.
    private var keychainOfferRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.l.t("kc_offer_title"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text(m.l.t("kc_offer_body"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                sheetButton(m.l.t("kc_not_now")) { m.keychainOfferDismissed = true }
                sheetButton(m.l.t("kc_move")) { m.moveKeys(toKeychain: true) }
                    .disabled(m.busy)
            }
        }
        .padding(10)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.bottom, 8)
    }

    /// One server: the row switches to it, the two icons edit or delete it.
    private func profileRow(_ p: Profile) -> some View {
        HStack(spacing: 2) {
            Button {
                close(.servers)
                m.switchServer(p.name)
            } label: {
                HStack {
                    Text(ProfileNaming.flag(p.country) ?? "·")
                        .frame(width: 18, alignment: .leading)
                    Text(p.display ?? Countries.name(p.country, lang: m.lang))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if p.keychain == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .opacity(0.7)
                            .help(m.l.t("kc_in_keychain"))
                            .accessibilityLabel(m.l.t("kc_in_keychain"))
                    }
                    Spacer()
                    Text((p.endpoint ?? "—").split(separator: ":").first.map(String.init) ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(m.isChosen(p) ? Palette.accentText.opacity(0.8) : Palette.secondary)
                }
                .padding(.leading, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            rowIcon("pencil", m.l.t("srv_edit"), active: m.isChosen(p)) {
                editName = p.name
                editError = nil
                editing = p.name
            }
            rowIcon("trash", m.l.t("srv_delete"), active: m.isChosen(p)) { pendingDelete = p }
        }
        .padding(.trailing, 4)
        .background(m.isChosen(p) ? Palette.accent : Palette.card)
        .foregroundStyle(m.isChosen(p) ? Palette.accentText : Palette.text)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.bottom, 3)
    }

    private func rowIcon(_ symbol: String, _ label: String, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Palette.accentText.opacity(0.85) : Palette.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Rename in place, or load a new `.conf` into the same profile.
    private func profileEditor(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(m.l.t("srv_name"), text: $editName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { save(p) }
            if let editError {
                Text(editError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                sheetButton(m.l.t("srv_replace")) {
                    editing = nil
                    m.replaceProfileConfig(p)
                }
                Spacer()
                sheetButton(m.l.t("srv_cancel")) { editing = nil }
                sheetButton(m.l.t("srv_save")) { save(p) }
            }
        }
        .padding(8)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.bottom, 3)
    }

    private func save(_ p: Profile) {
        editError = m.renameProfile(p, to: editName)
        if editError == nil { editing = nil }
    }

    private func sheetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .modifier(Chip())
            .foregroundStyle(Palette.text)
    }

    /// Let the user choose any `.conf` and copy it into the profile folder.
    ///
    /// Menfez ships no provider relationship, so this is the only way a new
    /// user gets their first server. The panel never sees the file's contents:
    /// the copy happens in `WireGuardProfiles.importConfig`, which writes with
    /// mode 0600 and refuses to overwrite without asking.
    private func importConfig() { m.chooseAndImportConfig() }

    // Internal, not private, so the DEBUG snapshot can draw it.
    var dnsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(m.l.t("dns_title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(m.l.t("dns_note"))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.bottom, 10)

            let presets = m.dns?.presets ?? []
            let fastest = presets.first(where: { $0.ok && ($0.ms ?? 0) > 0 })?.id
            if presets.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(m.l.t("testing"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.vertical, 10)
            }

            ForEach(presets) { p in
                Button {
                    close(.dns)
                    // One choice for both: Menfez's own lookups follow the
                    // provider picked for the Mac.
                    if let doh = DoHProvider(rawValue: p.id) { dohRaw = doh.rawValue }
                    m.setDNS(p.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(p.id == "system" ? m.l.t("automatic") : p.name)
                            .font(.system(size: 12))
                        if let address = p.v4.first {
                            Text(address)
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.7)
                        }
                        if fastest == p.id && p.active != true {
                            Text(m.l.t("fastest"))
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.success)
                        }
                        Spacer()
                        if p.v4.isEmpty {
                            Text(m.l.t("auto"))
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.secondary)
                        } else if let ms = p.ms {
                            Text("\(ms) ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(p.active ? Palette.accentText : Palette.secondary)
                        } else if p.ok == false {
                            Text(m.l.t("unreachable"))
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.danger)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(p.active == true ? Palette.accent : Palette.card)
                .foregroundStyle(p.active == true ? Palette.accentText : Palette.text)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.bottom, 3)
            }

            Divider().padding(.vertical, 8)
            HStack {
                Text(m.l.t("doh_title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(m.l.t("doh_note"))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondary)
            }
            // Plain chips rather than a segmented control: same look as the
            // list above, and it draws in the snapshot renderer.
            HStack(spacing: 4) {
                ForEach(DoHProvider.allCases, id: \.rawValue) { p in
                    let on = dohRaw == p.rawValue
                    Button { dohRaw = p.rawValue } label: {
                        Text(p.name)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(on ? Palette.accent : Palette.card)
                    .foregroundStyle(on ? Palette.accentText : Palette.text)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)

            // Tunnel-only: hidden for anyone without a usable tunnel and a server.
            if m.capabilities.tunnelAvailable && !m.profiles.isEmpty {
            Toggle(isOn: $dnsViaTunnel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.l.t("dns_tunnel"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text)
                    Text(m.l.t("dns_tunnel_note"))
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Palette.accent)
            .controlSize(.small)
            .onChange(of: dnsViaTunnel) { _ in
                m.dnsRoutingChanged()
                m.checkDNSRoutes()
            }
            if dnsViaTunnel && m.dnsStaysOutside {
                Text(m.l.t("dns_tunnel_private"))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            }

            HStack {
                Spacer()
                Button(m.l.t("close")) { close(.dns) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .modifier(Chip())
                    .foregroundStyle(Palette.text)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { m.checkDNSRoutes() }
        .background(Palette.bg)
    }

    /// Where a detail row's data comes from. Kept as a function rather than a
    /// stored value because the egress IP is the only row that needs one, and
    /// reading it at click time is what gets the value that is on screen.
    private func detailSheetData(_ what: String) -> DetailSheet {
        let value = what == "ip" ? m.cardIdentity.ip : nil
        var sheet = DetailSheet(title: m.l.t("det_" + what), what: what, value: value,
                                backend: m.backend)
        if what == "discord" {
            // Shown at once from the card's last probe, then refreshed on the
            // same path the card uses; see `Details.discordLive`.
            sheet.initial = Details.discordRows(probe: m.report?.discord ?? DiscordProbe(), names: nil)
            let backend = m.backend
            let port = m.probeProxyPort
            sheet.refresh = { backend.discordDetail(proxyPort: port) }
        }
        return sheet
    }
}

// MARK: - Sheet routes

/// The panels this window can present.
///
/// One enum instead of four booleans so "what is on screen" has exactly one
/// answer, and `SheetRouter` can refuse a second panel while one is up. The
/// detail panel carries its own data because two different rows open panels with
/// the same shape but different contents.
enum SheetRoute: Equatable {
    case servers
    case dns
    case help
    case about
    case whatsNew
    case siteTest
    case leakTest
    case sites
    case onboarding
    case detail(DetailSheet)
}


// MARK: - Detail sheet

struct DetailSheet: Identifiable {
    let id = UUID()
    let title: String
    let what: String
    let value: String?
    let backend: Backend
    /// Rows to show before `refresh` answers; with `refresh`, replaces the
    /// helper call.
    var initial: [DetailItem]? = nil
    var refresh: (@Sendable () -> [DetailItem])? = nil
}

extension DetailSheet: Equatable {
    /// Equality by identity, not by content.
    ///
    /// The route must match the panel that is actually open, and two visits to
    /// the same row are two panels: comparing `what` would let a queued close for
    /// the previous IP panel dismiss the one the user just opened. The id is
    /// unique per creation, which is exactly the question being asked.
    static func == (lhs: DetailSheet, rhs: DetailSheet) -> Bool { lhs.id == rhs.id }
}

struct DetailView: View {
    let sheet: DetailSheet
    let lang: Lang
    let onClose: () -> Void
    /// Fixed rows instead of a backend call; only the snapshot renderer sets it.
    var preview: [DetailItem]? = nil
    @State private var items: [DetailItem] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sheet.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.bottom, 12)

            if loading && preview == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L(lang: lang).t("working"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array((preview ?? items).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(L(lang: lang).detail(item.label))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                            .frame(width: WidthPolicy.detailLabel, alignment: .leading)
                        Text(L(lang: lang).detail(item.value))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }

            HStack {
                if copied {
                    Text(L(lang: lang).t("copied"))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.success)
                }
                if refreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button(L(lang: lang).t("close")) { onClose() }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .modifier(Chip())
                .foregroundStyle(Palette.text)
            }
            .padding(.top, 10)
        }
        .padding(16)
        // Same 440...620 band as the window. The detail rows are label + value
        // + Spacer, so the extra width goes to the value column, which is where
        // an IPv6 address or a route list actually needs it.
        .frame(minWidth: 400, idealWidth: 420, maxWidth: 560, alignment: .leading)
        .background(Palette.bg)
        .task {
            guard preview == nil else { return }
            if let refresh = sheet.refresh {
                items = sheet.initial ?? []
                loading = false
                refreshing = true
                let fresh = await Task.detached(priority: .userInitiated) { refresh() }.value
                if !fresh.isEmpty { items = fresh }
                refreshing = false
                return
            }
            let backend = sheet.backend
            let what = sheet.what
            let value = sheet.value
            let result = await Task.detached(priority: .userInitiated) {
                backend.detail(what, value: value)
            }.value
            items = result
            loading = false
        }
    }
}

// MARK: - App

/// Keeps the process alive when the window closes; the menu bar stays.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MenfezApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()

    init() {
        #if DEBUG
        Snapshots.renderIfRequested()
        #endif
        // Sparkle's scheduled checks run whether or not a menu is ever opened.
        _ = Updater.shared
    }

    var body: some Scene {
        // One window, not a group: "Open window" in the menu bar brings this
        // one back instead of stacking copies. Closing it leaves the app
        // running in the menu bar (see `AppDelegate`).
        Window(L(lang: model.lang).t("app"), id: MenuBarContent.mainWindowID) {
            ContentView(m: model)
        }
        .windowStyle(.hiddenTitleBar)
        // The window is exactly the content's size: fixed width, height
        // following the content as rows and pickers come and go.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                if Updater.shared.available {
                    Button(L(lang: model.lang).t("app_update_check")) {
                        Updater.shared.checkForUpdates()
                    }
                }
            }
            // The menu entry point is the same one-click action as the big
            // button: start the proxy and launch Discord. It needs no helper, so
            // it is the item that always works — the tunnel's own commands live
            // behind the capability check and the mode chips.
            CommandMenu("DPI") {
                Button(L(lang: model.lang).t("dpi_enable_discord")) {
                    model.enableDPIAndLaunchDiscord()
                }
                .disabled(model.busy)

                Button(L(lang: model.lang).t("discord_launch")) {
                    model.launchDiscord()
                }
                .disabled(!model.dpi.running)
                .help(model.dpiMode?.discordAvailability.reason ?? "")

                Button(L(lang: model.lang).t("dpi_probe")) {
                    model.runProbe()
                }
                .disabled(model.probing || !model.dpi.running)

                Button(L(lang: model.lang).t("sitetest_open")) {
                    model.siteTestRequests += 1
                }

                Divider()

                Button(L(lang: model.lang).t("dpi_stop")) {
                    model.disableDPI()
                }
                .disabled(!model.dpi.running)
            }
            CommandGroup(after: .help) {
                Button(L(lang: model.lang).t("export_log")) {
                    model.exportDebugLog()
                }
            }
        }

        MenuBarExtra {
            MenuBarContent(m: model)
        } label: {
            MenuBarIcon(mode: model.runMode)
        }

        Settings {
            SettingsView(m: model)
        }
    }
}
