import XCTest
@testable import MenfezCore

/// The alias table is the only thing standing between a user and a column full
/// of "AS47524 Turksat Uydu Haberlesme Kablo TV ve Isletme A.S.", so every
/// entry that people in Turkey actually meet is pinned here with its real
/// ipinfo string.
final class ShortISPTests: XCTestCase {

    // MARK: - Turkey

    func testTurksat() {
        XCTAssertEqual(ShortISP.short(
            "AS47524 Turksat Uydu Haberlesme Kablo TV ve Isletme A.S."), "Türksat")
        XCTAssertEqual(ShortISP.short("AS47524 Turksat"), "Türksat")
    }

    func testTurkTelekom() {
        XCTAssertEqual(ShortISP.short(
            "AS9121 Turk Telekomunikasyon Anonim Sirketi"), "Türk Telekom")
        XCTAssertEqual(ShortISP.short("AS9121 TTNet"), "Türk Telekom")
    }

    func testTurkcell() {
        XCTAssertEqual(ShortISP.short(
            "AS34984 Superonline Iletisim Hizmetleri A.S."), "Turkcell")
        XCTAssertEqual(ShortISP.short("AS16135 Turkcell"), "Turkcell")
    }

    func testVodafone() {
        XCTAssertEqual(ShortISP.short(
            "AS15924 Vodafone Net Iletisim Hizmetleri A.S."), "Vodafone")
    }

    func testTurkNet() {
        XCTAssertEqual(ShortISP.short(
            "AS51539 Turknet Iletisim Hizmetleri A.S."), "TurkNet")
    }

    func testGibirNet() {
        XCTAssertEqual(ShortISP.short(
            "AS208972 Gibirnet Iletisim Hizmetleri A.S."), "GibirNet")
    }

    func testMillenicom() {
        XCTAssertEqual(ShortISP.short(
            "AS34296 Millenicom Telekomunikasyon A.S."), "Millenicom")
    }

    func testNetSpeedAndComnet() {
        XCTAssertEqual(ShortISP.short("AS197328 NetSpeed Internet Hizmetleri"),
                       "NetSpeed")
        XCTAssertEqual(ShortISP.short("AS16371 Comnet Iletisim Hizmetleri"),
                       "Comnet")
    }

    // MARK: - VPN and hosting

    func testProtonAndDatacamp() {
        XCTAssertEqual(ShortISP.short("AS209103 Proton AG"), "Proton VPN")
        XCTAssertEqual(ShortISP.short("AS212238 Datacamp Limited"), "Datacamp")
        XCTAssertEqual(ShortISP.short("AS9009 M247 Europe SRL"), "M247")
    }

    func testHyperscalers() {
        XCTAssertEqual(ShortISP.short("AS16509 Amazon.com, Inc."), "Amazon AWS")
        XCTAssertEqual(ShortISP.short("AS15169 Google LLC"), "Google")
        XCTAssertEqual(ShortISP.short("AS8075 Microsoft Corporation"),
                       "Microsoft Azure")
        XCTAssertEqual(ShortISP.short("AS24940 Hetzner Online GmbH"), "Hetzner")
        XCTAssertEqual(ShortISP.short("AS16276 OVH SAS"), "OVH")
    }

    // MARK: - Fallbacks

    func testUnknownNameKeepsLeadingWord() {
        XCTAssertEqual(ShortISP.short("AS1234 Bilinmeyen Bir Sirket A.S."),
                       "Bilinmeyen")
    }

    func testDomainLikeName() {
        XCTAssertEqual(ShortISP.short("AS5678 foo.com.tr"), "Foo")
    }

    func testEmptyAndNil() {
        XCTAssertNil(ShortISP.short(nil))
        XCTAssertNil(ShortISP.short(""))
        XCTAssertNil(ShortISP.short("   "))
    }

    func testBareASNumberOnly() {
        // Nothing recognisable left; must not crash or return the AS prefix.
        // `XCTAssertNotNil(out == nil ? "nil" : out)` used to sit here and was a
        // tautology: the ternary made the value non-nil even when `out` was nil,
        // so the assertion held whatever `short` returned. The real promise is
        // that an org with nothing but a registry id yields no label at all,
        // rather than a bare "AS9999" in the provider column.
        let out = ShortISP.short("AS9999")
        XCTAssertNil(out, "a bare AS number produced the label \"\(out ?? "")\"")
        // Belt and braces for the case a future change starts returning
        // something: it must not be the registry id dressed up.
        XCTAssertFalse((out ?? "").hasPrefix("AS"))
    }

    func testLongLegalNameIsShort() {
        // The whole point: whatever comes back must fit a narrow column.
        let inputs = [
            "AS47524 Turksat Uydu Haberlesme Kablo TV ve Isletme A.S.",
            "AS9121 Turk Telekomunikasyon Anonim Sirketi",
            "AS34984 Superonline Iletisim Hizmetleri A.S.",
            "AS13335 Cloudflare, Inc.",
        ]
        for input in inputs {
            let out = try! XCTUnwrap(ShortISP.short(input))
            XCTAssertLessThanOrEqual(out.count, 16,
                                     "\(out) is too long for the column (from \(input))")
        }
    }
}
