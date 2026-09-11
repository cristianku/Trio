import Foundation

protocol AICredentialProvider {
    func apiKey() throws -> String
    func replaceKey(_ value: String) throws
    func deleteKey() throws
}

extension AICredentialProvider {
    func maskedAPIKey() throws -> String {
        let value = try apiKey()
        guard value.count > 18 else { return "••••••••" }
        return "\(value.prefix(10))…\(value.suffix(4))"
    }
}

final class KeychainAICredentialProvider: AICredentialProvider {
    static let key = "AIAssistant.OpenAI.apiKey"
    private let keychain: Keychain

    init(keychain: Keychain) { self.keychain = keychain }

    func apiKey() throws -> String {
        let result: Result<String?, KeychainError> = keychain.getValue(String.self, forKey: Self.key)
        guard let value = try? result.get(), !value.isEmpty else { throw AIError.missingCredential }
        return value
    }

    func replaceKey(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), value.count < 1024 else {
            throw AIError.missingCredential
        }
        let result: Result<Void, KeychainError> = keychain.setValue(value, forKey: Self.key)
        do { try result.get() } catch { throw AIError.missingCredential }
    }

    func deleteKey() throws {
        do { try keychain.removeObject(forKey: Self.key).get() } catch { throw AIError.missingCredential }
    }
}
