import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Framepick

final class CodexAITests: XCTestCase {
    private func suggestion(overrides: [String: Any] = [:]) throws -> String {
        var values = AIAdjustmentSuggestion.ranges.mapValues { max(0, $0.lowerBound) as Any }
        values["contrast"] = 1.0; values["saturation"] = 1.0
        values.merge(overrides) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["adjustments": values, "explanation": "노출을 자연스럽게 유지합니다."])
        return String(decoding: data, as: UTF8.self)
    }

    func testStrictSuggestionRejectsUnexpectedCommandsOutOfRangeAndBooleans() throws {
        let parsed = try AIAdjustmentSuggestion.parse(suggestion(overrides: ["exposure": 0.5, "faceSmoothing": 0.2]))
        XCTAssertEqual(parsed.values["exposure"], 0.5)
        XCTAssertEqual(parsed.values["faceSmoothing"], 0.2)
        XCTAssertThrowsError(try AIAdjustmentSuggestion.parse(suggestion(overrides: ["command": "anything"])))
        XCTAssertThrowsError(try AIAdjustmentSuggestion.parse(suggestion(overrides: ["exposure": 4.1])))
        XCTAssertThrowsError(try AIAdjustmentSuggestion.parse(suggestion(overrides: ["faceSmoothing": true])))
        XCTAssertThrowsError(try AIAdjustmentSuggestion.parse("```json\n{}\n```"))
    }

    func testMessageDecoderHandlesSplitUTF8MultipleLinesAndSizeLimit() throws {
        let text = #"{"id":7,"result":{"label":"사진"}}"# + "\n" + #"{"method":"account/updated","params":{}}"# + "\n"
        let data = Data(text.utf8)
        var decoder = CodexMessageDecoder()
        var messages: [[String: Any]] = []
        for byte in data { messages += try decoder.append(Data([byte])) }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0]["result"] as? [String: String])?["label"], "사진")
        var small = CodexMessageDecoder(maximumLineBytes: 10)
        XCTAssertThrowsError(try small.append(Data(repeating: 65, count: 11)))
        var invalid = CodexMessageDecoder()
        XCTAssertThrowsError(try invalid.append(Data("not JSON\n".utf8)))
    }

    @MainActor
    func testMockRequestCorrelationAndServerRequestRefusal() async throws {
        var messages: [[String: Any]] = []
        let service = CodexAIService(transport: { messages.append($0) })
        let request = Task { try await service.request("account/read", params: ["refreshToken": false]) }
        await Task.yield()
        let id = try XCTUnwrap(messages.first?["id"] as? Int)
        service.receive(try JSONSerialization.data(withJSONObject: ["id": id + 5, "result": [:]]) + Data([10]))
        service.receive(try JSONSerialization.data(withJSONObject: ["id": id, "result": ["account": NSNull()]]) + Data([10]))
        let response = try await request.value
        XCTAssertTrue(response["account"] is NSNull)
        service.receive(Data(#"{"id":99,"method":"item/commandExecution/requestApproval","params":{}}"#.utf8) + Data([10]))
        XCTAssertEqual((messages.last?["error"] as? [String: Any])?["code"] as? Int, -32601)
        service.disconnect()
    }

    @MainActor
    func testMockCancellationAndTimeoutResumePendingRequests() async throws {
        let service = CodexAIService(transport: { _ in })
        let request = Task { try await service.request("account/read", params: [:]) }
        await Task.yield(); request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await service.request("account/read", params: [:], timeout: 0.01); XCTFail("Missing timeout") }
        catch CodexAIError.timeout {} catch { XCTFail("Unexpected error: \(error)") }
        service.disconnect()
    }

    @MainActor
    func testDisconnectFinishesOutstandingRequests() async throws {
        let service = CodexAIService(transport: { _ in })
        let request = Task { try await service.request("account/read", params: [:]) }
        await Task.yield(); service.disconnect()
        do { _ = try await request.value; XCTFail("Disconnected request completed") }
        catch CodexAIError.disconnected {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testMockPendingLoginCancellationIgnoresLateResponse() async throws {
        var messages: [[String: Any]] = []
        let service = CodexAIService(transport: { messages.append($0) })
        let login = Task { await service.signIn() }
        for _ in 0..<20 where messages.isEmpty { await Task.yield() }
        let id = try XCTUnwrap(messages.first?["id"] as? Int)
        XCTAssertEqual(messages.first?["method"] as? String, "account/login/start")
        await service.cancelSignIn()
        await login.value
        // An inert URL guarantees the test cannot open a real authentication page.
        service.receive(try JSONSerialization.data(withJSONObject: ["id": id, "result": ["loginId": "cancelled", "authUrl": "invalid://mock"]]) + Data([10]))
        XCTAssertFalse(service.isSigningIn)
        XCTAssertNil(service.errorMessage)
        service.disconnect()
    }

    @MainActor
    func testMockAnalysisUsesEphemeralThreadAndSanitizedImageThenCleansUp() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("private-name.png")
        let imageDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, Fixture.image(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        let replyText = try suggestion(overrides: ["exposure": 0.25])
        weak var target: CodexAIService?
        var methods: [String] = []
        var sentImagePath: String?
        let service = CodexAIService(homeURL: dir.appendingPathComponent("isolated-ai"), transport: { message in
            guard let id = message["id"] as? Int, let method = message["method"] as? String else { return }
            methods.append(method)
            let params = message["params"] as? [String: Any] ?? [:]
            @MainActor func respond(_ result: [String: Any]) throws {
                target?.receive(try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10]))
            }
            switch method {
            case "account/read": try respond(["account": ["type": "chatgpt", "email": "mock@example.test", "planType": "test"]])
            case "thread/start":
                XCTAssertEqual(params["ephemeral"] as? Bool, true)
                XCTAssertEqual(params["sandbox"] as? String, "read-only")
                XCTAssertEqual(params["approvalPolicy"] as? String, "never")
                try respond(["thread": ["id": "mock-thread"]])
            case "turn/start":
                let inputs = try XCTUnwrap(params["input"] as? [[String: Any]])
                XCTAssertEqual(inputs.count, 2)
                XCTAssertEqual(inputs.last?["type"] as? String, "localImage")
                sentImagePath = try XCTUnwrap(inputs.last?["path"] as? String)
                XCTAssertNotEqual(sentImagePath, photo.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: sentImagePath!))
                XCTAssertNotNil(params["outputSchema"])
                try respond(["turn": ["id": "mock-turn"]])
                target?.receive(try JSONSerialization.data(withJSONObject: ["method": "item/completed", "params": ["threadId": "mock-thread", "item": ["type": "agentMessage", "phase": "final_answer", "text": replyText]]]) + Data([10]))
                target?.receive(Data(#"{"method":"turn/completed","params":{"threadId":"mock-thread","turn":{"status":"completed"}}}"#.utf8) + Data([10]))
            case "thread/unsubscribe": try respond([:])
            default: XCTFail("Unexpected RPC: \(method)")
            }
        })
        target = service
        let result = try await service.suggest(imageURL: photo, instructions: "자연스럽게 보정")
        XCTAssertEqual(result.values["exposure"], 0.25)
        XCTAssertEqual(methods, ["account/read", "thread/start", "turn/start", "thread/unsubscribe"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(sentImagePath)))
        XCTAssertFalse(service.isBusy)
        service.disconnect()
    }

    @MainActor
    func testLoginURLIsOfficialHTTPSOnlyAndToolConfigurationIsRestricted() {
        XCTAssertTrue(CodexAIService.isOfficialLoginURL(URL(string: "https://auth.openai.com/authorize?state=test")!))
        for url in ["https://auth.openai.com.evil.test/", "http://auth.openai.com/", "file:///tmp/login", "https://attacker@chatgpt.com/"] {
            XCTAssertFalse(CodexAIService.isOfficialLoginURL(URL(string: url)!))
        }
        let config = CodexAIService.safeConfiguration
        XCTAssertEqual(config["features.shell_tool"] as? Bool, false)
        XCTAssertEqual(config["features.code_mode_host"] as? Bool, false)
        XCTAssertEqual(config["features.browser_use"] as? Bool, false)
        XCTAssertEqual(config["features.plugins"] as? Bool, false)
        XCTAssertEqual(config["web_search"] as? String, "disabled")
        XCTAssertEqual(config["approval_policy"] as? String, "never")
        var effective: [String: Any] = ["features": Dictionary(uniqueKeysWithValues: CodexAIService.disabledFeatures.map { ($0, false) }), "web_search": "disabled"]
        XCTAssertTrue(CodexAIService.configurationIsRestricted(effective))
        effective["mcp_servers"] = ["unexpected": ["enabled": true]]
        XCTAssertFalse(CodexAIService.configurationIsRestricted(effective))
        effective["mcp_servers"] = [:] as [String: Any]
        effective["features"] = ["shell_tool": true]
        XCTAssertFalse(CodexAIService.configurationIsRestricted(effective))
    }

    func testAIUploadCopyStripsGPSAndDownsizesWithoutChangingOriginal() throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("private-original.jpg")
        let image = Fixture.image(width: 2000, height: 1000)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLongitude: 127.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: sourceURL)
        let prepared = try CodexAIService.prepareImage(sourceURL, in: dir.appendingPathComponent("upload"))
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(prepared as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 800)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertEqual(prepared.lastPathComponent, "selected-photo.jpg")
    }
}
