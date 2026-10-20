import Foundation

public enum MatchError: Error, CustomStringConvertible {
    case none(kind: String, query: String, candidates: [String])
    case ambiguous(kind: String, query: String, matches: [String])

    public var description: String {
        switch self {
        case let .none(kind, query, candidates):
            let list = candidates.isEmpty ? "none available" : candidates.joined(separator: ", ")
            return "No \(kind) matches \"\(query)\". Available: \(list)"
        case let .ambiguous(kind, query, matches):
            return "\"\(query)\" matches several \(kind)s: \(matches.joined(separator: ", ")). Be more specific."
        }
    }
}

/// Resolves what a person types ("spotify", "airpods", "Sam's TV") to one item.
public enum Matcher {
    /// Tries, in order: exact name, exact key (bundle ID / UID), name prefix, name or key substring.
    public static func match<T>(_ query: String, in items: [T], kind: String,
                                name: (T) -> String, key: (T) -> String) throws -> T {
        let q = normalize(query)
        guard !q.isEmpty else { throw MatchError.none(kind: kind, query: query, candidates: items.map(name)) }
        for tier in 0..<4 {
            let hits = items.filter { item in
                let n = normalize(name(item)), k = normalize(key(item))
                switch tier {
                case 0: return n == q
                case 1: return k == q
                case 2: return n.hasPrefix(q)
                default: return n.contains(q) || k.contains(q)
                }
            }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw MatchError.ambiguous(kind: kind, query: query, matches: hits.map(name)) }
        }
        throw MatchError.none(kind: kind, query: query, candidates: items.map(name))
    }

    /// Case-, accent- and apostrophe-insensitive ("Sam’s TV" == "sams tv").
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
