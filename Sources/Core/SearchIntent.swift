import Foundation

/// A web search worked out from what the user said: which site, and what to search for.
/// Done in code because the small model mixes up "search YouTube" (open YouTube) with
/// "search for youtube" (a Google search), and drops searches after "open a new tab".
struct SearchIntent: Equatable {
    enum Site: String, CaseIterable {
        case youtube, google, wikipedia, amazon

        var name: String { ["youtube": "YouTube", "google": "Google", "wikipedia": "Wikipedia", "amazon": "Amazon"][rawValue]! }
        var home: String {
            ["youtube": "https://www.youtube.com", "google": "https://www.google.com",
             "wikipedia": "https://en.wikipedia.org", "amazon": "https://www.amazon.com"][rawValue]!
        }
        var search: String {
            ["youtube": "https://www.youtube.com/results?search_query=", "google": "https://www.google.com/search?q=",
             "wikipedia": "https://en.wikipedia.org/w/index.php?search=", "amazon": "https://www.amazon.com/s?k="][rawValue]!
        }
    }

    /// nil means an ordinary web search (Google).
    let site: Site?
    /// nil means just open the site.
    let query: String?

    var url: String {
        let site = site ?? .google
        guard let query else { return site.home }
        return site.search + Planner.formEncode(query)
    }

    var label: String {
        guard let query else { return "Open \((site ?? .google).name)" }
        guard let site, site != .google else { return "Search the web for \(query)" }
        return "Search \(site.name) for \(query)"
    }

    static let sites = Site.allCases.map(\.rawValue).joined(separator: "|")
    static let browsers = #"(?:google\s+chrome|chrome|safari|brave|firefox|microsoft\s+edge|edge|arc|opera|vivaldi)"#

    /// "search youtube for cats"
    static let siteFor = Pattern(#"\bsearch\s+("# + sites + #")\s+for\s+(.+)$"#, dotAll: true)
    /// "search for cats on youtube"
    static let onSite = Pattern(#"\bsearch\s+(?:for\s+)?(.+?)\s+(?:on|in)\s+("# + sites + #")\b"#, dotAll: true)
    /// "search youtube" (optionally "… in chrome")
    static let siteOnly = Pattern(#"\bsearch\s+("# + sites + #")(?:\s+(?:in|on|using|with)\s+(?:the\s+)?"# + browsers + #")?\s*[.!]?$"#)
    /// "search for cats", "search the web for cats", "google cats", "look up cats"
    static let plain = Pattern(#"\b(?:search|google|look\s+up)\s+(?:the\s+(?:web|internet)\s+)?(?:for\s+)?(.+)$"#, dotAll: true)
    /// "… in chrome" at the end of a query
    static let browserSuffix = Pattern(#"\s+(?:in|on|using|with)\s+(?:the\s+)?"# + browsers + #"(?:\s+browser)?\s*[.!]?$"#)
    /// "in chrome", "using safari" anywhere
    static let browserMention = Pattern(#"\b(?:in|on|using|with)\s+(?:the\s+)?("# + browsers + #")\b"#)

    static func parse(_ said: String) -> SearchIntent? {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = siteFor.firstMatch(in: text) {
            return SearchIntent(site: Site(rawValue: match.group(1).lowercased()), query: clean(match.group(2)))
        }
        if let match = onSite.firstMatch(in: text) {
            return SearchIntent(site: Site(rawValue: match.group(2).lowercased()), query: clean(match.group(1)))
        }
        if let match = siteOnly.firstMatch(in: text) {
            return SearchIntent(site: Site(rawValue: match.group(1).lowercased()), query: nil)
        }
        if let match = plain.firstMatch(in: text), let query = clean(match.group(1)) {
            return SearchIntent(site: nil, query: query)
        }
        return nil
    }

    /// The browser named in the sentence, if any ("… in Safari").
    static func mentionedBrowser(_ said: String) -> String? {
        browserMention.firstMatch(in: said)?.group(1)
    }

    private static func clean(_ query: String) -> String? {
        var query = query
        if let suffix = browserSuffix.firstMatch(in: query) { query = String(query[..<suffix.range(at: 0).lowerBound]) }
        query = query.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        return query.isEmpty ? nil : query
    }
}
