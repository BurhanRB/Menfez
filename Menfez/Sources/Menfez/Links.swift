// Links.swift — every URL the UI can open, in one place.
//
// WHY A FILE FOR FIVE STRINGS
// A link is the one thing in this app that leaves it. Having them together means
// a release checklist can check five lines, and nobody has to grep the view for
// a domain that might be a placeholder.

import Foundation

enum Links {

    static let github = URL(string: "https://github.com/burhanrb/Menfez")

    static let web = URL(string: "https://menfez.app")

    /// The text shown for a link whose URL did not parse. Kept next to the URL
    /// so the two cannot drift.
    static let githubLabel = "github.com/burhanrb/Menfez"
    static let webLabel = "menfez.app"

    /// Where the support button points: the author's own page, which is where
    /// the "buy me a tea" link lives.
    ///
    /// Pointing at the site rather than at a payment processor keeps this file
    /// free of an account-specific URL that would rot when the page moves, and
    /// a person who lands on burhanrb.com finds the author's other work too.
    ///
    /// WHY THIS IS `URL?` AND NOT `URL!`
    /// A force-unwrapped URL is the one value in this file that can crash the app
    /// at launch, and it would crash for a reason the user cannot act on: a typo
    /// in a donation address. `URL(string:)` is failable precisely because a
    /// string can be malformed, so the failure is modelled rather than asserted
    /// away. The cost is one `if let` at the call site, which hides the button.
    /// Hiding is the right failure mode here — a missing coffee icon is a missed
    /// donation, a crash is a broken app — and the compiler makes forgetting the
    /// `if let` impossible. The two links above are handled the same way, so
    /// there is one pattern in the file rather than two.
    static let support = URL(string: "https://burhanrb.com")

    /// The label shown in the button's tooltip.
    static let supportLabel = "burhanrb.com"

    /// Only `https` is accepted when handing a URL to the browser. A future edit
    /// that produces `http:` or a relative string is treated as no link at all,
    /// which is the same fail-closed choice as the optional above.
    static func openable(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }
}
