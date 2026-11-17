import XCTest
// The link table lives in the app target, which a test cannot import. The rules
// it encodes are asserted against local copies of the same literals, so a change
// to `Links` that breaks one of them fails here only if the rule itself is
// wrong — see the note on duplication below.

/// The outbound-link policy.
///
/// Two things are worth a test and both are cheap: that the shipped URLs parse,
/// and that the `openable` gate rejects what it is meant to reject. The second is
/// the one that would matter in a bad edit — an `http:` link or a relative string
/// would otherwise be handed straight to the browser.
final class LinkPolicyTests: XCTestCase {

    /// The same rule as `Links.openable`, restated.
    ///
    /// Duplicated rather than imported because `Menfez` is an executable target
    /// and XCTest cannot link it. The duplication is the limitation; keeping the
    /// rule identical and the comment here is the mitigation.
    private func openable(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }

    // MARK: - The shipped links

    /// The three addresses in the About panel and the header must parse. A literal
    /// that does not is the case the optional type exists for, but it should never
    /// reach a release.
    func testShippedLinksParse() {
        let shipping = [
            "https://github.com/burhanrb/Menfez",
            "https://menfez.app",
            "https://menfez.app/destek",
        ]
        for raw in shipping {
            let url = URL(string: raw)
            XCTAssertNotNil(url, "\(raw) must parse")
            XCTAssertNotNil(openable(url), "\(raw) must be openable")
        }
    }

    /// Every shipped link is https. A donation page over plain http would leak
    /// the fact that the user clicked it, and the gate above would hide the
    /// button — silently, which is why it is asserted here instead.
    func testShippedLinksAreHTTPS() {
        for raw in ["https://github.com/burhanrb/Menfez",
                    "https://menfez.app",
                    "https://menfez.app/destek"] {
            XCTAssertEqual(URL(string: raw)?.scheme, "https", raw)
        }
    }

    // MARK: - The gate

    func testPlainHTTPIsRejected() {
        XCTAssertNil(openable(URL(string: "http://menfez.app")))
    }

    func testNonWebSchemesAreRejected() {
        // A `file:` link opened from an about panel would be a way to make the
        // app open something that is not a web page.
        XCTAssertNil(openable(URL(string: "file:///etc/passwd")))
        XCTAssertNil(openable(URL(string: "javascript:alert(1)")))
        XCTAssertNil(openable(URL(string: "mailto:someone@example.com")))
    }

    func testRelativeAndMalformedStringsAreRejected() {
        XCTAssertNil(openable(URL(string: "github.com/burhanrb/Menfez")),
                     "no scheme means no browser")
        XCTAssertNil(openable(nil))
    }

    /// `https:` with no host is not a page.
    func testSchemeWithoutHostIsRejected() {
        XCTAssertNil(openable(URL(string: "https://")))
    }

    /// Case matters only for the comparison, not for the URL: `HTTPS://` is the
    /// same scheme and must be accepted.
    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertNotNil(openable(URL(string: "HTTPS://menfez.app")))
    }

    func testQueryAndFragmentSurviveTheGate() {
        let url = openable(URL(string: "https://menfez.app/destek?utm=app#top"))
        XCTAssertEqual(url?.query, "utm=app")
        XCTAssertEqual(url?.fragment, "top")
    }
}
