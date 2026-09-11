import Foundation
import Testing

@testable import Trio

@Suite("AI Responses API") struct AIOpenAIClientTests {
    @Test("Native Responses request uses instructions, input and previous_response_id, without tools") func encoding() throws {
        let request = OpenAIRequest(model: "test-model", instructions: "read only", input: [.init(role: "user", content: "why?")], previousResponseID: "resp_123", store: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["previous_response_id"] as? String == "resp_123")
        #expect(object["instructions"] as? String == "read only")
        #expect(object["tools"] == nil)
        #expect(object["max_output_tokens"] as? Int == 2000)
        #expect(object["store"] as? Bool == true)
    }

    @Test("All output_text blocks are decoded, reasoning and unknown output ignored") func decoding() throws {
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: Data(#"{"id":"resp_1","status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"First"},{"type":"output_text","text":"Second"}]}]}"#.utf8))
        #expect(try response.answer() == "First\nSecond")
    }

    @Test("Incomplete and tool-only responses never become an answer") func incomplete() throws {
        for fixture in [
            #"{"id":"resp_1","status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#,
            #"{"id":"resp_1","status":"completed","output":[{"type":"function_call","name":"bolus","arguments":"{}"}]}"#
        ] {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: Data(fixture.utf8))
            #expect(throws: (any Error).self) { try response.answer() }
        }
    }
}
