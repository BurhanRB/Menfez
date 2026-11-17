// CountryNames.swift — the two-letter code table.
//
// WHY IN THE CORE
// Three places need it: the profile namer (a filename segment "RO" must render
// as "Romanya"), the flag renderer, and the UI. Keeping a second copy in the
// view layer meant the two could disagree about what "RO" is called.
//
// The Turkish and English spellings are both stored rather than translated at
// the call site, because a country name is not a UI string with a placeholder —
// it is data, and a wrong translation here is worse than a missing one.

import Foundation

public enum CountryNames {
    /// Two-letter ISO code to (Turkish, English) display name.
    public static let table: [String: (tr: String, en: String)] = [
        "TR": ("Türkiye", "Turkey"), "BG": ("Bulgaristan", "Bulgaria"),
        "DE": ("Almanya", "Germany"), "GR": ("Yunanistan", "Greece"),
        "NL": ("Hollanda", "Netherlands"), "RO": ("Romanya", "Romania"),
        "US": ("ABD", "United States"), "GB": ("Birleşik Krallık", "United Kingdom"),
        "FR": ("Fransa", "France"), "CH": ("İsviçre", "Switzerland"),
        "SE": ("İsveç", "Sweden"), "JP": ("Japonya", "Japan"),
        "SG": ("Singapur", "Singapore"), "PL": ("Polonya", "Poland"),
        "CA": ("Kanada", "Canada"), "AT": ("Avusturya", "Austria"),
        "IT": ("İtalya", "Italy"), "ES": ("İspanya", "Spain"),
        "NO": ("Norveç", "Norway"), "FI": ("Finlandiya", "Finland"),
        "DK": ("Danimarka", "Denmark"), "BE": ("Belçika", "Belgium"),
        "CZ": ("Çekya", "Czechia"), "HU": ("Macaristan", "Hungary"),
        "IE": ("İrlanda", "Ireland"), "PT": ("Portekiz", "Portugal"),
        "RU": ("Rusya", "Russia"), "UA": ("Ukrayna", "Ukraine"),
        "BR": ("Brezilya", "Brazil"), "AR": ("Arjantin", "Argentina"),
        "MX": ("Meksika", "Mexico"), "AU": ("Avustralya", "Australia"),
        "NZ": ("Yeni Zelanda", "New Zealand"), "KR": ("Güney Kore", "South Korea"),
        "IN": ("Hindistan", "India"), "ZA": ("Güney Afrika", "South Africa"),
        "AE": ("BAE", "UAE"), "IL": ("İsrail", "Israel"),
        "LT": ("Litvanya", "Lithuania"), "LV": ("Letonya", "Latvia"),
        "EE": ("Estonya", "Estonia"), "SK": ("Slovakya", "Slovakia"),
        "SI": ("Slovenya", "Slovenia"), "HR": ("Hırvatistan", "Croatia"),
        "RS": ("Sırbistan", "Serbia"), "MD": ("Moldova", "Moldova"),
        "IS": ("İzlanda", "Iceland"), "LU": ("Lüksemburg", "Luxembourg"),
    ]

    /// Display name for a code, or the code itself when unknown.
    public static func name(_ code: String?, turkish: Bool) -> String? {
        guard let code, let pair = table[code.uppercased()] else { return code }
        return turkish ? pair.tr : pair.en
    }
}
