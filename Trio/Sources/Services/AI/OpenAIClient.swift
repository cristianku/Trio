import Foundation

struct OpenAIRequest: Codable {
    struct Input: Codable {
        let role: String
        let content: String
    }
    let model: String
    let instructions: String
    let input: [Input]
    let previousResponseID: String?
    let store: Bool
    var maxOutputTokens = 2000

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store
        case previousResponseID = "previous_response_id"
        case maxOutputTokens = "max_output_tokens"
    }
}

struct OpenAIResponse: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
        let type: String
        let content: [Content]?
    }
    let id: String
    let status: String
    let output: [Output]

    func answer() throws -> String {
        guard status == "completed" else { throw AIError.invalidResponse }
        var parts: [String] = []
        for item in output where item.type == "message" {
            for content in item.content ?? [] {
                if content.type == "output_text", let text = content.text { parts.append(text) }
                if content.type == "refusal", let refusal = content.refusal { parts.append(refusal) }
            }
        }
        let text = parts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
        return text
    }
}

struct OpenAIErrorResponse: Decodable {
    struct Detail: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
    let error: Detail
}

protocol OpenAIClient {
    func respond(to request: OpenAIRequest) async throws -> OpenAIResponse
}

/// No SDK, request/body logging, tools, redirects, caching or automatic POST retry.
final class URLSessionOpenAIClient: NSObject, OpenAIClient, URLSessionTaskDelegate {
    private let credentials: AICredentialProvider
    private let redactor: AIContextRedactor
    private let configuration: URLSessionConfiguration
    private let maxResponseBytes = 1000000

    init(credentials: AICredentialProvider, redactor: AIContextRedactor, configuration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        self.redactor = redactor
        self.configuration = configuration
        super.init()
    }

    func respond(to request: OpenAIRequest) async throws -> OpenAIResponse {
        try Task.checkCancellation()
        let key = try credentials.apiKey()
        // Sanitize every input again at the egress boundary. Keep protocol metadata out of semantic key filtering.
        let sanitized = OpenAIRequest(model: request.model, instructions: request.instructions,
                                      input: request.input.map { .init(role: $0.role, content: redactor.redact($0.content)) },
                                      previousResponseID: request.previousResponseID, store: request.store)
        let body = try JSONEncoder().encode(sanitized)
        guard body.count <= AIContextLimits.requestBytes else { throw AIError.requestTooLarge }
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard response.expectedContentLength <= maxResponseBytes else { throw AIError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxResponseBytes else { throw AIError.responseTooLarge }
                data.append(byte)
            }
            guard (200..<300).contains(response.statusCode) else {
                let detail = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data)
                let message: String
                switch response.statusCode {
                case 401: message = "Authentication failed. Replace the API key in AI Settings."
                case 429: message = "Rate or quota limit reached. Check API billing and try later."
                case 500...599: message = "Service temporarily unavailable. Try again later."
                default: message = detail.map { String(redactor.redact($0.error.message).prefix(300)) } ?? "Request rejected. Check model and configuration."
                }
                throw AIError.api(status: response.statusCode, message: message)
            }
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            _ = try decoded.answer()
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch is DecodingError {
            throw AIError.invalidResponse
        } catch {
            throw AIError.network
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
