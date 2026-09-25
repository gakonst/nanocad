import XCTest
@testable import NanoCAD

final class NanocodexClientTests: XCTestCase {
    func testSplitUnicodeAndCRLF() throws {
        var parser = NanocodexSSEParser()
        let wire = "id: 9007199254740993\r\ndata: {\"type\":\"event\",\"turn_id\":\"turn-1\",\"event\":{\"type\":\"assistant.delta\",\"payload\":{\"text\":\"圆角 🔧\"}}}\r\n\r\n"
        var events: [NanocodexEvent] = []
        for byte in wire.utf8 { if let event = try parser.append(byte: byte) { events.append(event) } }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.cursor, "9007199254740993")
        XCTAssertEqual(events.first?.text, "圆角 🔧")
        XCTAssertEqual(events.first?.turnID, "turn-1")
    }

    func testControlFrameDoesNotBecomeAssistantText() throws {
        var parser = NanocodexSSEParser()
        var events: [NanocodexEvent] = []
        for byte in ": keepalive\n\n: cursor 12\n\n".utf8 {
            if let event = try parser.append(byte: byte) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, "cursor")
        XCTAssertEqual(events.first?.cursor, "12")
        XCTAssertEqual(events.first?.text, "")
    }

    func testMultilineDataAndFinalMessage() throws {
        var parser = NanocodexSSEParser()
        let wire = "id: 45\ndata: {\"type\":\"turn_completed\",\"id\":\"turn-2\",\ndata: \"final_message\":\"Saved model.step\"}\n\n"
        var last: NanocodexEvent?
        for byte in wire.utf8 { if let event = try parser.append(byte: byte) { last = event } }
        XCTAssertEqual(last?.text, "Saved model.step")
        XCTAssertEqual(last?.turnID, "turn-2")
        XCTAssertEqual(last?.isTerminal, true)
    }

    func testRealToolAndAssistantEnvelopeFields() throws {
        let frames = [
            #"{"type":"event","turn_id":"turn-1","event":{"type":"tool.call","payload":{"name":"exec_command","call_id":"call-1","model_call_index":3,"arguments":{"cmd":"python model.py","Authorization":"Bearer fixture-secret"}}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"tool.result","payload":{"tool":"exec_command","call_id":"call-1","status":"error","result":"failed","structured_result":{"exit_code":1}}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"assistant.message","payload":{"model_call_index":3,"item_id":"msg-1","phase":"commentary","text":"Updating the bracket."}}}"#
        ]
        var parser = NanocodexSSEParser(), events: [NanocodexEvent] = []
        for (index, frame) in frames.enumerated() {
            for byte in "id: \(index + 1)\ndata: \(frame)\n\n".utf8 {
                if let event = try parser.append(byte: byte) { events.append(event) }
            }
        }
        XCTAssertEqual(events[0].toolName, "exec_command")
        XCTAssertEqual(events[0].callID, "call-1")
        XCTAssertEqual(events[0].modelCallIndex, 3)
        XCTAssertTrue(events[0].arguments?.contains("python model.py") == true)
        XCTAssertFalse(events[0].arguments?.contains("fixture-secret") == true)
        XCTAssertEqual(events[1].toolName, "exec_command")
        XCTAssertEqual(events[1].toolStatus, "error")
        XCTAssertTrue(events[1].result?.contains("exit_code") == true)
        XCTAssertEqual(events[2].itemID, "msg-1")
        XCTAssertEqual(events[2].phase, "commentary")
    }

    func testToolNameAndToolAliasesAndReasoningExclusion() throws {
        let frames = [
            #"{"type":"event","turn_id":"turn-1","event":{"type":"tool.call","payload":{"name":"preferred","tool":"old-name","arguments":"read model.step"}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"tool.call","payload":{"tool":"exec_command","arguments":"python model.py"}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"tool.result","payload":{"tool":{"name":"exec_command"},"status":"FAILED","result":"Invalid model"}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"reasoning.delta","payload":{"text":"private reasoning","arguments":"private arguments"}}}"#,
            #"{"type":"event","turn_id":"turn-1","event":{"type":"assistant.message","payload":{"phase":"analysis","text":"private analysis"}}}"#
        ]
        var parser = NanocodexSSEParser(), events: [NanocodexEvent] = []
        for (index, frame) in frames.enumerated() {
            for byte in "id: \(index + 1)\ndata: \(frame)\n\n".utf8 {
                if let event = try parser.append(byte: byte) { events.append(event) }
            }
        }
        XCTAssertEqual(events.map(\.toolName), ["preferred", "exec_command", "exec_command", nil, nil])
        XCTAssertEqual(events[2].toolStatus, "failed")
        XCTAssertTrue(events[2].toolFailed)
        XCTAssertEqual(events[3].text, "")
        XCTAssertNil(events[3].arguments)
        XCTAssertEqual(events[4].text, "")
        XCTAssertEqual(events[4].cursor, "5") // Hidden events still checkpoint the observer.
    }

    func testCredentialOriginRejectsPathAndPlainHTTP() {
        let key = "ncx_live_abcdefghijkl_" + String(repeating: "x", count: 43)
        XCTAssertThrowsError(try NanocodexCredentials(origin: "http://example.com", apiKey: key))
        XCTAssertThrowsError(try NanocodexCredentials(origin: "https://example.com/account", apiKey: key))
        XCTAssertNoThrow(try NanocodexCredentials(origin: "https://example.com/", apiKey: key))
    }
}
