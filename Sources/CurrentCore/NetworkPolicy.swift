import Foundation

public struct ServerRule: Codable, Equatable, Identifiable {
    public var id: String
    public var host: String
    public var maxConnections: Int

    public init(id: String = UUID().uuidString, host: String, maxConnections: Int = 2) {
        self.id = id
        self.host = host
        self.maxConnections = maxConnections
    }

    public func validated() throws -> ServerRule {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...16).contains(maxConnections) else {
            throw CurrentError.invalid("Each server rule needs an identity and 1–16 connections.")
        }
        guard !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CurrentError.invalid("Use a hostname such as example.org or *.example.org in server rules.")
        }
        var normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        let wildcard = normalized.hasPrefix("*.")
        let hostname = wildcard ? String(normalized.dropFirst(2)) : normalized
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        let lettersAndNumbers = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let allowed = lettersAndNumbers.union(CharacterSet(charactersIn: "-"))
        guard !hostname.isEmpty, hostname.utf8.count <= 253,
              labels.allSatisfy({ label in
                  guard !label.isEmpty, label.utf8.count <= 63,
                        let first = label.unicodeScalars.first, let last = label.unicodeScalars.last else { return false }
                  return lettersAndNumbers.contains(first) && lettersAndNumbers.contains(last)
                      && label.unicodeScalars.allSatisfy { allowed.contains($0) }
              }) else {
            throw CurrentError.invalid("Use a hostname such as example.org or *.example.org in server rules. Omit URLs, paths and ports.")
        }
        let numericAddress = labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        if numericAddress {
            guard !wildcard, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
                throw CurrentError.invalid("Use a valid IPv4 address without wildcards, or a hostname.")
            }
        }
        var rule = self
        rule.host = normalized
        return rule
    }

    public func matches(_ url: URL) -> Bool {
        guard let rule = try? validated(), var hostname = url.host?.lowercased() else { return false }
        if hostname.hasSuffix(".") { hostname.removeLast() }
        if rule.host.hasPrefix("*.") { return hostname.hasSuffix(String(rule.host.dropFirst())) }
        return hostname == rule.host
    }
}

public extension AppSettings {
    var effectiveQuotaPeriodSeconds: Int { quotaPeriodSeconds ?? 3600 }

    func validatedServerRules() throws -> [ServerRule] {
        let rules = try (serverRules ?? []).map { try $0.validated() }
        guard Set(rules.map(\.id)).count == rules.count else {
            throw CurrentError.invalid("Each server rule must have a different identity.")
        }
        guard Set(rules.map(\.host)).count == rules.count else {
            throw CurrentError.invalid("Keep one connection rule per hostname or wildcard.")
        }
        return rules
    }

    func validateNetworkPolicy() throws {
        _ = try validatedServerRules()
        guard (1...31_536_000).contains(effectiveQuotaPeriodSeconds) else {
            throw CurrentError.invalid("Choose a quota window between 1 second and 365 days.")
        }
        if let userAgent {
            guard userAgent.utf8.count <= 4096,
                  !userAgent.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CurrentError.invalid("The User-Agent must be a single line of at most 4096 bytes.")
            }
        }
    }

    /// Exact hosts take precedence over wildcards; the longest wildcard wins.
    func connectionLimit(for url: URL) -> Int? {
        guard let rules = try? validatedServerRules() else { return nil }
        let matches = rules.filter { $0.matches(url) }
        if let exact = matches.first(where: { !$0.host.hasPrefix("*.") }) { return exact.maxConnections }
        return matches.max(by: { $0.host.count < $1.host.count })?.maxConnections
    }
}
