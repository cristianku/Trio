import Foundation

protocol AIContextRedactor {
    func redact(_ text: String) -> String
    func sanitizeJSON(_ data: Data) throws -> Data
}

/// Sanitize strings before JSON encoding so quotes, slashes and newlines cannot evade text matching.
/// Field allowlists are the primary boundary; these rules are additional protection for unstructured evidence.
final class DefaultAIContextRedactor: AIContextRedactor {
    private let knownSecrets: () -> [String]
    private let marker = "[REDACTED]"
    private static let secretName = "(?:authorization|proxy[-_ ]?authorization|api[-_ ]?(?:key|secret)|access[-_ ]?token|refresh[-_ ]?token|id[-_ ]?token|token|secret|password|passwd|credential|client[-_ ]?secret|cookie|set-cookie|x-auth-token)"

    init(knownSecrets: @escaping () -> [String] = { [] }) {
        self.knownSecrets = knownSecrets
    }

    func redact(_ text: String) -> String {
        var result = text
        for secret in knownSecrets().filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            for value in Set([secret, secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret]) {
                result = result.replacingOccurrences(of: value, with: marker)
            }
        }
        // Remove entire URLs, including encoded credentials, path tokens, queries and fragments.
        // Therapy explanations do not need network addresses.
        result = replacing(#"(?i)\b(?:https?|wss?)://[^\s<>\"']+"#, in: result)
        result = replacing(#"(?i)\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]+"#, in: result)
        result = replacing(#"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/%=-]+"#, in: result)
        result = replacing(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, in: result)
        // Cookie/Digest headers contain multiple semicolon/comma-separated credentials: remove the entire header.
        result = replacing(#"(?im)(?:^|(?<=\s))["']?(?:authorization|proxy[-_ ]?authorization|cookie|set-cookie)["']?[ \t]*[:=][^\r\n]*"#, in: result)
        // Escaped JSON field names in log strings: discard the remainder of that credential-bearing line.
        // Parsing arbitrary nested log payloads is unreliable; retaining a secret fragment is worse than omitting a log line.
        result = replacing(#"(?im)\b\#(Self.secretName)(?:\\+["'])[ \t]*[:=][^\r\n]*"#, in: result)
        // Escaped quotes belong to the secret, not to the end delimiter.
        result = replacing(#"(?im)["']?\#(Self.secretName)["']?\s*[:=]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n,;&}]+)"#, in: result)
        return result
    }

    func sanitizeJSON(_ data: Data) throws -> Data {
        func sanitize(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    let sensitive = ["authorization", "apikey", "apisecret", "token", "secret", "password", "passwd", "credential", "cookie"]
                        .contains { normalized.contains($0) }
                    return (key, sensitive ? marker : sanitize(value))
                })
            }
            if let array = value as? [Any] { return array.map(sanitize) }
            if let string = value as? String { return redact(string) }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: sanitize(object), options: [.sortedKeys, .fragmentsAllowed])
    }

    private func replacing(_ pattern: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return marker }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: marker)
    }
}
