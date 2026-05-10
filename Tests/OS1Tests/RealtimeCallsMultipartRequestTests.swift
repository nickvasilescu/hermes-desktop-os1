import Foundation
import Testing
@testable import OS1

struct RealtimeCallsMultipartRequestTests {
    @Test
    func createsNamedFormFieldsWithoutFileUploads() throws {
        let request = RealtimeCallsMultipartRequest.make(
            sdp: "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n",
            session: #"{"type":"realtime","model":"gpt-realtime-2"}"#,
            boundary: "test-boundary"
        )

        let body = String(decoding: request.body, as: UTF8.self)

        #expect(request.contentType == "multipart/form-data; boundary=test-boundary")
        #expect(body.contains(#"Content-Disposition: form-data; name="sdp""#))
        #expect(body.contains(#"Content-Disposition: form-data; name="session""#))
        #expect(body.contains("Content-Type: application/sdp"))
        #expect(body.contains("Content-Type: application/json"))
        #expect(!body.contains("filename="))
    }

    @Test
    func anyEncodablePreservesMCPJSONSchemaNumbers() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "minLength": NSNumber(value: 1),
                ],
                "x": [
                    "type": "integer",
                    "minimum": NSNumber(value: 0),
                ],
                "enabled": [
                    "type": "boolean",
                    "default": NSNumber(value: false),
                ],
            ],
        ]

        let data = try JSONEncoder().encode(AnyEncodable(schema))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let name = try #require(properties["name"] as? [String: Any])
        let x = try #require(properties["x"] as? [String: Any])
        let enabled = try #require(properties["enabled"] as? [String: Any])

        #expect(name["minLength"] as? Int == 1)
        #expect(x["minimum"] as? Int == 0)
        #expect(enabled["default"] as? Bool == false)
    }

    @Test
    func realtimeOrgoMCPUsesBoundedPublicDefaults() {
        #expect(RealtimeOrgoMCPBridge.defaultToolsets == "core,screen,files")
        #expect(RealtimeOrgoMCPBridge.defaultDisabledTools == "orgo_upload_file")
        #expect(RealtimeOrgoMCPBridge.defaultReadOnly == "true")
        #expect(RealtimeOrgoMCPBridge.defaultPackage == "@orgo-ai/mcp@3.0.0")
    }
}
