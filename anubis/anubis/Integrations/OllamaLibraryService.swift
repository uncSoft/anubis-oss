//
//  OllamaLibraryService.swift
//  anubis
//
//  Fetches and parses the public Ollama model catalog from
//  https://ollama.com/library (and /search?q=…). Ollama has no
//  documented JSON API for catalog browsing, but the public site
//  renders entries with explicit `x-test-*` Alpine.js attributes
//  (intended for automation / E2E testing) which makes parsing
//  stable enough to rely on.
//
//  HTML shape we parse, per entry:
//
//    <li x-test-model>
//      <a href="/library/{name}">
//        <div x-test-model-title title="{name}">
//          <span>{name}</span>
//          <p>{description}</p>
//        </div>
//        <span x-test-capability>{tools|vision|thinking|…}</span>
//        <span x-test-size>{8b|70b|405b|…}</span>
//        <span x-test-pull-count>{count, e.g. 115M}</span>
//        <span x-test-tag-count>{N}</span>
//        <span x-test-updated>{relative time}</span>
//      </a>
//    </li>
//
//  Both /library and /search?q= return the same per-entry shape, so
//  one parser handles both. Results are cached in-memory for 24h so
//  repeated opens of the browse sheet don't re-fetch.
//

import Foundation

/// One row from the Ollama library — what the browse sheet renders.
struct OllamaLibraryEntry: Identifiable, Hashable, Sendable {
    let name: String                  // e.g. "llama3.1"
    let description: String           // one-line marketing blurb
    let capabilities: [String]        // ["tools", "vision", "thinking"]
    let sizes: [String]               // ["8b", "70b", "405b"]
    let pullCount: String             // human-readable: "115M"
    let updated: String               // human-readable: "1 year ago"

    var id: String { name }

    /// What you'd pass to `/api/pull`. When the user clicks the
    /// model itself (no size selected) we just pull the bare name
    /// and let Ollama serve its default tag.
    func pullSpec(size: String? = nil) -> String {
        guard let size = size, !size.isEmpty else { return name }
        return "\(name):\(size)"
    }
}

/// Lightweight HTML scraper for the Ollama model library. Cache TTL
/// 24h — the catalog is slow-moving by Ollama's own cadence and we
/// don't want to hammer ollama.com on every browse-sheet open.
actor OllamaLibraryService {
    static let shared = OllamaLibraryService()

    private struct CacheEntry {
        let entries: [OllamaLibraryEntry]
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]   // key: query ("" = library home)
    private let cacheTTL: TimeInterval = 60 * 60 * 24

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        // Identify ourselves so Ollama can rate-limit / block us
        // specifically if we ever become a problem, rather than
        // poisoning the well for all macOS / Safari clients.
        config.httpAdditionalHeaders = [
            "User-Agent": "AnubisOSS/1 (+https://github.com/uncSoft/anubis-oss)"
        ]
        return URLSession(configuration: config)
    }()

    /// Fetch the top library entries (no query) or filtered results.
    /// Pass nil/empty query for the default browse view.
    func fetch(query: String? = nil, forceRefresh: Bool = false) async throws -> [OllamaLibraryEntry] {
        let key = (query?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if !forceRefresh,
           let cached = cache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.entries
        }

        let url: URL
        if key.isEmpty {
            url = URL(string: "https://ollama.com/library")!
        } else {
            var components = URLComponents(string: "https://ollama.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: key)]
            url = components.url!
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaLibraryError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw OllamaLibraryError.decodingFailed
        }

        let entries = Self.parse(html: html)
        cache[key] = CacheEntry(entries: entries, fetchedAt: Date())
        return entries
    }

    /// Clear the cache — used by a Refresh action in the UI.
    func invalidate() {
        cache.removeAll()
    }

    // MARK: - HTML Parsing

    /// Regex-based on purpose: the page is small and pulling in a full HTML
    /// parser dependency for one scraper would be overkill.
    ///
    /// ollama.com dropped its `x-test-*` attribute markers in mid-2026, which
    /// silently emptied the browser (every block regex returned zero matches).
    /// The current markup is parsed first; the legacy marker-based parse stays
    /// as a fallback in case they ever bring the test hooks back.
    static func parse(html: String) -> [OllamaLibraryEntry] {
        let modern = parseModernMarkup(html)
        if !modern.isEmpty { return modern }
        return parseLegacyMarkup(html)
    }

    /// Current ollama.com markup (Aug 2026): each model is an
    /// `<a href="/library/{name}" class="group …">` card. Field anchors:
    /// description keeps its `max-w-lg` class, capability chips are the
    /// indigo spans, size chips the blue spans, and pulls/updated sit next
    /// to their labelled sibling spans.
    static func parseModernMarkup(_ html: String) -> [OllamaLibraryEntry] {
        guard let cardRegex = try? NSRegularExpression(
            pattern: #"<a href="/library/([^"]+)"[^>]*class="group[\s\S]*?</a>"#,
            options: []
        ) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        var results: [OllamaLibraryEntry] = []

        cardRegex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match = match,
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: html),
                  let blockRange = Range(match.range(at: 0), in: html)
            else { return }
            let name = String(html[nameRange])
            let inner = String(html[blockRange])
            guard !name.isEmpty else { return }

            let description = decodeHTMLEntities(
                firstMatch(inner, #"<p class="max-w-lg[^"]*">([\s\S]*?)</p>"#)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) ?? ""
            )
            let capabilities = allMatches(inner, #"<span[^>]*text-indigo-600[^>]*>([^<]+)</span>"#)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let sizes = allMatches(inner, #"<span[^>]*text-blue-600[^>]*>([^<]+)</span>"#)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let pullCount = firstMatch(inner, #"<span[^>]*>\s*([0-9][\d.,]*[KMB]?)\s*</span>\s*<span[^>]*>&nbsp;Pulls"#)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updated = firstMatch(inner, #"Updated&nbsp;</span>\s*<span[^>]*>([^<]+)</span>"#)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            results.append(OllamaLibraryEntry(
                name: name,
                description: description,
                capabilities: capabilities,
                sizes: sizes,
                pullCount: pullCount,
                updated: updated
            ))
        }

        return results
    }

    /// Pre-2026 markup: `<li x-test-model>…</li>` blocks with `x-test-*`
    /// attribute markers on every field.
    static func parseLegacyMarkup(_ html: String) -> [OllamaLibraryEntry] {
        guard let liRegex = try? NSRegularExpression(
            pattern: "<li[^>]*x-test-model[^>]*>([\\s\\S]*?)</li>",
            options: []
        ) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        var results: [OllamaLibraryEntry] = []

        liRegex.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
            guard let match = match,
                  match.numberOfRanges >= 2,
                  let inner = Range(match.range(at: 1), in: html).map({ String(html[$0]) })
            else { return }

            // Name: prefer the title attribute on x-test-model-title;
            // fall back to the /library/{name} href.
            let name = firstMatch(inner, #"x-test-model-title[^>]*title="([^"]+)""#)
                ?? firstMatch(inner, #"href="/library/([^"]+)""#)
                ?? ""
            guard !name.isEmpty else { return }

            // Description: first <p> with the marketing class shape.
            // Strip whitespace + collapse newlines + decode entities
            // (descriptions occasionally contain &#39; / &amp; etc).
            let description = decodeHTMLEntities(
                firstMatch(inner, #"<p class="max-w-lg[^"]*">([\s\S]*?)</p>"#)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) ?? ""
            )

            let capabilities = allMatches(inner, #"<span[^>]*x-test-capability[^>]*>([^<]+)</span>"#)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let sizes = allMatches(inner, #"<span[^>]*x-test-size[^>]*>([^<]+)</span>"#)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let pullCount = firstMatch(inner, #"<span[^>]*x-test-pull-count[^>]*>([^<]+)</span>"#)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let updated = firstMatch(inner, #"<span[^>]*x-test-updated[^>]*>([^<]+)</span>"#)?
                .trimmingCharacters(in: .whitespaces) ?? ""

            results.append(OllamaLibraryEntry(
                name: name,
                description: description,
                capabilities: capabilities,
                sizes: sizes,
                pullCount: pullCount,
                updated: updated
            ))
        }

        return results
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = r.firstMatch(in: s, options: [], range: range),
              m.numberOfRanges >= 2,
              let captured = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[captured])
    }

    /// Decode the handful of HTML entities that actually show up in
    /// Ollama's library descriptions. Cheap inline replacement rather
    /// than dragging NSAttributedString-based HTML parsing into a
    /// hot loop.
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        let replacements: [(String, String)] = [
            ("&#39;", "'"), ("&#x27;", "'"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&amp;", "&"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "),
        ]
        for (entity, char) in replacements {
            if out.contains(entity) {
                out = out.replacingOccurrences(of: entity, with: char)
            }
        }
        return out
    }

    private static func allMatches(_ s: String, _ pattern: String) -> [String] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        var out: [String] = []
        r.enumerateMatches(in: s, options: [], range: range) { match, _, _ in
            guard let m = match,
                  m.numberOfRanges >= 2,
                  let captured = Range(m.range(at: 1), in: s) else { return }
            out.append(String(s[captured]))
        }
        return out
    }
}

enum OllamaLibraryError: LocalizedError {
    case httpStatus(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Ollama library returned HTTP \(code)."
        case .decodingFailed:
            return "Could not decode the Ollama library response."
        }
    }
}

