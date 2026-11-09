import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A bounded, quote-aware scanner for static markup. JavaScript is deliberately
/// neither evaluated during discovery nor retained in offline HTML documents.
enum OfflineMarkup {
    enum Kind { case html, css, binary }
    struct Reference { let raw: String; let base: URL; let navigation: Bool }
    private struct Attribute {
        let name: String
        let value: String
        let valueRange: NSRange
        let fullRange: NSRange
    }
    private struct Tag {
        let name: String
        let range: NSRange
        let attributes: [Attribute]
        let content: NSRange?
    }
    private struct Edit { let range: NSRange; let replacement: String }
    private static let tagPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style)\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*?>([\s\S]*?)(?:</\1\s*>|$)|<([a-z][a-z0-9:-]*)\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*?>"#, options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(pattern: #"([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#, options: [.caseInsensitive])
    private static let cssPattern = try! NSRegularExpression(pattern: #"/\*[\s\S]*?(?:\*/|$)|url\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s'\"()]*))\s*\)|@import\s+(?:\"([^\"]*)\"|'([^']*)')|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, options: [.caseInsensitive])

    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    static func kind(mime: String, url: URL, data: Data) -> Kind {
        if ["text/html", "application/xhtml+xml"].contains(mime) { return .html }
        if mime == "text/css" { return .css }
        if mime.isEmpty {
            if url.pathExtension.lowercased() == "css" { return .css }
            let prefix = text(data.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { return .html }
        }
        return .binary
    }

    static func references(in source: String, kind: Kind, base: URL) -> [Reference] {
        if kind == .css { return cssReferences(source).map { Reference(raw: $0.0, base: base, navigation: false) } }
        guard kind == .html else { return [] }
        let tags = scan(source)
        let base = documentBase(tags: tags, fallback: base)
        let ns = source as NSString
        var references: [Reference] = []
        for tag in tags where !["base", "script"].contains(tag.name) {
            if tag.name == "style", let content = tag.content {
                references += cssReferences(ns.substring(with: content)).map { Reference(raw: $0.0, base: base, navigation: false) }
            }
            for attribute in tag.attributes {
                let raw = decodeEntities(attribute.value)
                if attribute.name == "style" {
                    references += cssReferences(raw).map { Reference(raw: $0.0, base: base, navigation: false) }
                } else if ["srcset", "imagesrcset"].contains(attribute.name) {
                    references += srcset(raw).map { Reference(raw: $0.0, base: base, navigation: false) }
                } else if isURL(attribute.name, tag: tag.name) {
                    if tag.name == "form" { continue }
                    references.append(Reference(raw: raw, base: base, navigation: ["a", "area", "iframe", "frame"].contains(tag.name)))
                }
            }
        }
        return references
    }

    static func rewrite(_ source: String, kind: Kind, base: URL, mapping: [String: String]) -> String {
        if kind == .css { return rewriteCSS(source, base: base, mapping: mapping) }
        guard kind == .html else { return source }
        let tags = scan(source)
        let base = documentBase(tags: tags, fallback: base)
        let ns = source as NSString
        var edits: [Edit] = []
        for tag in tags {
            let attributes = Dictionary(tag.attributes.map { ($0.name, decodeEntities($0.value)) }, uniquingKeysWith: { first, _ in first })
            let metadata = attributes["http-equiv"]?.lowercased() ?? ""
            if ["script", "base"].contains(tag.name) || (tag.name == "meta" && ["refresh", "content-security-policy"].contains(metadata)) {
                edits.append(Edit(range: tag.range, replacement: "")); continue
            }
            if tag.name == "style", let content = tag.content {
                edits.append(Edit(range: content, replacement: rewriteCSS(ns.substring(with: content), base: base, mapping: mapping)))
            }
            for attribute in tag.attributes {
                if attribute.name.hasPrefix("on") || attribute.name == "srcdoc" || attribute.name == "integrity" {
                    edits.append(Edit(range: attribute.fullRange, replacement: "")); continue
                }
                let raw = decodeEntities(attribute.value)
                let value: String
                if attribute.name == "style" { value = rewriteCSS(raw, base: base, mapping: mapping) }
                else if ["srcset", "imagesrcset"].contains(attribute.name) {
                    value = srcset(raw).map { localURL($0.0, base: base, mapping: mapping) + ($0.1.isEmpty ? "" : " " + $0.1) }.joined(separator: ", ")
                } else if isURL(attribute.name, tag: tag.name) { value = tag.name == "form" ? "#" : localURL(raw, base: base, mapping: mapping) }
                else { continue }
                edits.append(Edit(range: attribute.valueRange, replacement: encodeAttribute(value)))
            }
        }
        let rewritten = applying(edits, to: source)
        let policy = "default-src 'none'; script-src 'none'; style-src 'self' 'unsafe-inline' file:; img-src 'self' data: file:; font-src 'self' data: file:; media-src 'self' data: file:; frame-src 'self' file:; object-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'"
        let metadata = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">"
        // Place the policy before any untrusted token. A head-shaped string in
        // a title, textarea or malformed document must not hide the policy.
        return "<!doctype html>\n" + metadata + rewritten
    }

    private static func isURL(_ attribute: String, tag: String) -> Bool {
        ["href", "src", "poster", "data-src", "action"].contains(attribute) || (attribute == "data" && tag == "object")
    }
    private static func documentBase(tags: [Tag], fallback: URL) -> URL {
        guard let raw = tags.first(where: { $0.name == "base" })?.attributes.first(where: { $0.name == "href" })?.value,
              let base = OfflineURL.normalized(decodeEntities(raw), relativeTo: fallback) else { return fallback }
        return base
    }
    private static func localURL(_ raw: String, base: URL, mapping: [String: String]) -> String {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.hasPrefix("#") || raw.lowercased().hasPrefix("data:") { return raw }
        guard let normalized = OfflineURL.normalized(raw, relativeTo: base) else {
            if raw.lowercased().hasPrefix("mailto:") || raw.lowercased().hasPrefix("tel:") { return raw }
            return "#"
        }
        let fragment = URLComponents(url: URL(string: raw, relativeTo: base)!.absoluteURL, resolvingAgainstBaseURL: true)?.percentEncodedFragment
        let path = mapping[normalized.absoluteString] ?? normalized.absoluteString
        return path + (fragment.map { "#" + $0 } ?? "")
    }
    private static func rewriteCSS(_ css: String, base: URL, mapping: [String: String]) -> String {
        applying(cssReferences(css).map { Edit(range: $0.1, replacement: localURL($0.0, base: base, mapping: mapping)) }, to: css)
    }
    private static func cssReferences(_ css: String) -> [(String, NSRange)] {
        let ns = css as NSString
        return cssPattern.matches(in: css, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = (1...5).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }), range.length <= 8192 else { return nil }
            let value = ns.substring(with: range)
            guard !value.isEmpty, !value.contains("\\") else { return nil }
            return (value, range)
        }
    }
    private static func srcset(_ value: String) -> [(String, String)] {
        // Common density/width candidates; commas inside data URLs are preserved.
        var result: [(String, String)] = []
        var remaining = value[...]
        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0.isWhitespace || $0 == "," })
            if remaining.isEmpty { break }
            let isData = remaining.lowercased().hasPrefix("data:")
            let urlEnd = remaining.firstIndex { $0.isWhitespace || (!isData && $0 == ",") } ?? remaining.endIndex
            let raw = String(remaining[..<urlEnd]); remaining = remaining[urlEnd...]
            if remaining.first == "," { result.append((raw, "")); remaining = remaining.dropFirst(); continue }
            remaining = remaining.drop(while: \.isWhitespace)
            let descriptorEnd = remaining.firstIndex(of: ",") ?? remaining.endIndex
            let descriptor = remaining[..<descriptorEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((raw, descriptor)); remaining = remaining[descriptorEnd...]
            if !remaining.isEmpty { remaining = remaining.dropFirst() }
        }
        return result
    }
    private static func scan(_ source: String) -> [Tag] {
        let ns = source as NSString
        return tagPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let special = match.range(at: 1).location != NSNotFound
            let nameRange = match.range(at: special ? 1 : 3)
            guard nameRange.location != NSNotFound else { return nil }
            let name = ns.substring(with: nameRange).lowercased()
            let openingRange = special ? NSRange(location: match.range.location, length: match.range(at: 2).location - match.range.location) : match.range
            let opening = ns.substring(with: openingRange)
            let openingNS = opening as NSString
            let attributes = attributePattern.matches(in: opening, range: NSRange(location: 0, length: openingNS.length)).compactMap { attribute -> Attribute? in
                guard let value = (2...4).map({ attribute.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return nil }
                let fullRange = NSRange(location: openingRange.location + attribute.range.location, length: attribute.range.length)
                return Attribute(name: openingNS.substring(with: attribute.range(at: 1)).lowercased(), value: openingNS.substring(with: value), valueRange: NSRange(location: openingRange.location + value.location, length: value.length), fullRange: fullRange)
            }
            return Tag(name: name, range: match.range, attributes: attributes, content: special ? match.range(at: 2) : nil)
        }
    }
    private static func applying(_ edits: [Edit], to source: String) -> String {
        let output = NSMutableString(string: source)
        var lowerBound = output.length
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(edit.range) <= lowerBound {
            output.replaceCharacters(in: edit.range, with: edit.replacement); lowerBound = edit.range.location
        }
        return output as String
    }
    private static func encodeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        guard let document = try? XMLDocument(xmlString: "<html><body><p title=\"" + escaped + "\"></p></body></html>", options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let element = try? document.nodes(forXPath: "//p").first as? XMLElement,
              let decoded = element.attribute(forName: "title")?.stringValue else { return value }
        return decoded
    }
}
