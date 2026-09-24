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

    func testCredentialOriginRejectsPathAndPlainHTTP() {
        let key = "ncx_live_abcdefghijkl_" + String(repeating: "x", count: 43)
        XCTAssertThrowsError(try NanocodexCredentials(origin: "http://example.com", apiKey: key))
        XCTAssertThrowsError(try NanocodexCredentials(origin: "https://example.com/account", apiKey: key))
        XCTAssertNoThrow(try NanocodexCredentials(origin: "https://example.com/", apiKey: key))
    }
}
