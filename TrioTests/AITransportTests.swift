import Foundation
import Testing

@testable import Trio

@Suite("AI native HTTP transport", .serialized) struct AITransportTests {
    private func client() -> URLSessionOpenAIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIURLProtocolFixture.self]
        return URLSessionOpenAIClient(
            credentials: FixtureAICredentials(),
            redactor: DefaultAIContextRedactor(knownSecrets: { ["sk-proj-transportFixture123"] }),
            configuration: configuration
        )
    }

    private var request: OpenAIRequest {
        .init(
            model: "test-model",
            instructions: "Explain",
            input: [.init(role: "user", content: "key sk-proj-transportFixture123")],
            previousResponseID: nil,
            store: false
        )
    }

    @Test("Authorization stays in header; body is redacted") func successfulRequest() async throws {
        AIURLProtocolFixture.handler = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-transportFixture123")
            let body = AIURLProtocolFixture.body(request)
            #expect(!String(decoding: body, as: UTF8.self).contains("sk-proj-transportFixture123"))
            #expect(String(decoding: body, as: UTF8.self).contains("REDACTED"))
            return (
                200,
                Data(
                    #"{"id":"resp_http","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Explanation"}]}]}"#
                        .utf8
                )
            )
        }
        let response = try await client().respond(to: request)
        #expect(try response.answer() == "Explanation")
    }

    @Test("Planning schema and output budget survive transport sanitization") func planningSchema() async throws {
        AIURLProtocolFixture.handler = { request in
            let object = try! JSONSerialization.jsonObject(with: AIURLProtocolFixture.body(request)) as! [String: Any]
            #expect(object["max_output_tokens"] as? Int == 1000)
            let format = (object["text"] as? [String: Any])?["format"] as? [String: Any]
            #expect(format?["type"] as? String == "json_schema")
            #expect(format?["strict"] as? Bool == true)
            #expect((format?["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
            return (
                200,
                Data(
                    #"{"id":"plan","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{}"}]}]}"#
                        .utf8
                )
            )
        }
        var planned = request
        planned.text = AIPlanTextFormat()
        planned.maxOutputTokens = 1000
        _ = try await client().respond(to: planned)
    }

    @Test("HTTP errors use a localized message without exposing server text or retrying") func httpError() async throws {
        var calls = 0
        AIURLProtocolFixture.handler = { _ in
            calls += 1
            return (
                400,
                Data(
                    #"{"error":{"message":"Invalid token: hiddenAuthValue123","type":"invalid_request_error","code":null}}"#
                        .utf8
                )
            )
        }
        do {
            _ = try await client().respond(to: request)
            Issue.record("Expected rejection")
        } catch let error as AIError {
            #expect(!error.localizedDescription.contains("hiddenAuthValue123"))
            #expect(
                error
                    .localizedDescription == "OpenAI (400): " +
                    String(localized: "Request rejected. Check model and configuration.")
            )
        }
        #expect(calls == 1)
    }

    @Test("Cancellation stops URLSession request") func cancellation() async throws {
        AIURLProtocolFixture.handler = nil
        let client = client()
        let request = request
        let task = Task { try await client.respond(to: request) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

struct FixtureAICredentials: AICredentialProvider {
    func apiKey() throws -> String { "sk-proj-transportFixture123" }
    func replaceKey(_: String) throws {}
    func deleteKey() throws {}
}

final class AIURLProtocolFixture: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
