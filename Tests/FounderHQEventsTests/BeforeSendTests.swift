import Foundation
import XCTest
@testable import FounderHQEvents

final class BeforeSendTests: XCTestCase {
    @MainActor
    func testHookEnvelopeContract() async throws {
        struct Case {
            let name: String
            let original: String
            let patch: [String: Any]
            let kept: Bool
            let expected: [String: Any]
            let absent: [String]
            init(_ name: String, original: String = "custom", patch: [String: Any],
                 kept: Bool = true, expected: [String: Any] = [:], absent: [String] = []) {
                self.name = name; self.original = original; self.patch = patch
                self.kept = kept; self.expected = expected; self.absent = absent
            }
        }
        let v4 = "12345678-1234-4abc-8abc-123456789abc"
        let v7 = "12345678-1234-7abc-babc-123456789abc"
        let cases: [Case] = [
            .init("unknown keys", patch: ["extra": true, "options": ["process_person_profile": true, "extra": 1, "cookieless_mode": true]], expected: ["options": ["process_person_profile": true]], absent: ["extra"]),
            .init("padded control rename", patch: ["event": " $mobile_purchase_claim"], kept: false),
            .init("control rename", patch: ["event": "$mobile_purchase_claim"], kept: false),
            .init("own internal name", original: "$set", patch: [:], expected: ["event": "$set"]),
            .init("public name trimmed", patch: ["event": " public.name \n"], expected: ["event": "public.name"]),
            .init("empty name", patch: ["event": " \n"], kept: false),
            .init("invalid UUID", patch: ["uuid": "no"], kept: false),
            .init("v4 UUID", patch: ["uuid": v4], expected: ["uuid": v4]),
            .init("uppercase UUID", patch: ["uuid": v4.uppercased()], expected: ["uuid": v4.uppercased()]),
            .init("UUID variant", patch: ["uuid": "12345678-1234-4abc-7abc-123456789abc"], kept: false),
            .init("UUID version", patch: ["uuid": "12345678-1234-0abc-8abc-123456789abc"], kept: false),
            .init("trim identity", patch: ["distinct_id": " user_42 \n"], expected: ["distinct_id": "user_42"]),
            .init("empty identity", patch: ["distinct_id": " \n"], kept: false),
            .init("illegal identity", patch: ["distinct_id": " null "], kept: false),
            .init("long identity", patch: ["distinct_id": String(repeating: "a", count: 401)], kept: false),
            .init("whole seconds", patch: ["timestamp": "2026-09-23T12:00:00Z"], expected: ["timestamp": "2026-09-23T12:00:00Z"]),
            .init("fraction", patch: ["timestamp": "2026-09-23T12:00:00.123456789Z"]),
            // Ingest takes UTC only: an offset timestamp is queued as the same instant in UTC.
            .init("offset rewritten to UTC", patch: ["timestamp": "2026-09-23T17:30:00+05:30"], expected: ["timestamp": "2026-09-23T12:00:00.000Z"]),
            .init("negative offset fraction rewritten to UTC", patch: ["timestamp": "2026-09-23T05:00:00.1-07:00"], expected: ["timestamp": "2026-09-23T12:00:00.100Z"]),
            .init("February overflow", patch: ["timestamp": "2026-02-30T12:00:00Z"], kept: false),
            .init("no zone", patch: ["timestamp": "2026-09-23T12:00:00"], kept: false),
            .init("hour overflow", patch: ["timestamp": "2026-09-23T24:00:00Z"], kept: false),
            .init("zone overflow", patch: ["timestamp": "2026-09-23T12:00:00+24:00"], kept: false),
            .init("v4 session", patch: ["session_id": v4], absent: ["session_id"]),
            .init("v7 session", patch: ["session_id": v7], expected: ["session_id": v7]),
            .init("invalid session", patch: ["session_id": 12], absent: ["session_id"]),
            .init("window kept", patch: ["window_id": "window"], expected: ["window_id": "window"]),
            .init("window empty removed", patch: ["window_id": ""], absent: ["window_id"]),
            .init("window blank removed", patch: ["window_id": "  "], absent: ["window_id"]),
            .init("window trimmed", patch: ["window_id": " window "], expected: ["window_id": "window"]),
            .init("window of 200 UTF-16 units", patch: ["window_id": String(repeating: "😀", count: 100)], expected: ["window_id": String(repeating: "😀", count: 100)]),
            .init("window past 200 UTF-16 units", patch: ["window_id": String(repeating: "😀", count: 101)], absent: ["window_id"]),
            .init("window long", patch: ["window_id": String(repeating: "a", count: 201)], absent: ["window_id"]),
            .init("window type", patch: ["window_id": 12], absent: ["window_id"]),
            .init("nonboolean profile", patch: ["options": ["process_person_profile": "true"]], kept: false),
            .init("numeric profile", patch: ["options": ["process_person_profile": 1]], kept: false),
            .init("array properties", patch: ["properties": [1, 2]], kept: false),
            .init("null properties", patch: ["properties": NSNull()], kept: false),
        ]
        for test in cases {
            // Typed Swift results cannot contain arbitrary keys or invalid property
            // types. Decoding exercises that boundary inside the throwing hook.
            let patchData = try JSONSerialization.data(withJSONObject: test.patch)
            let client = makePropertiesClient(beforeSend: { event in
                var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
                let patch = try XCTUnwrap(JSONSerialization.jsonObject(with: patchData) as? [String: Any])
                wire.merge(patch) { _, new in new }
                return try JSONDecoder().decode(FounderHQEvent.self, from: JSONSerialization.data(withJSONObject: wire))
            }, clock: BeforeSendClock())
            if test.original == "$set" {
                await client.setPersonPropertiesAndWait(["plan": "pro"])
                await client.identifyAndWait("user_42")
                // identifiedOnly defers $set until identified; emit it now.
                await client.setPersonPropertiesAndWait(["plan": "team"])
            } else {
                await client.captureAndWait(test.original)
            }
            let events = try await propertiesQueue(client)
            let matches = test.original == "$set" ? events.filter { $0.event == "$set" } : events
            XCTAssertEqual(matches.count, test.kept ? 1 : 0, test.name)
            if let event = matches.first {
                let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
                for (key, expected) in test.expected {
                    XCTAssertEqual(wire[key] as? NSObject, expected as? NSObject, "\(test.name): \(key)")
                }
                for key in test.absent { XCTAssertNil(wire[key], "\(test.name): \(key)") }
            }
        }
    }

    func testTimestampCalendarValidationAndEquivalentInstants() throws {
        let date = try XCTUnwrap(parseEventTimestamp("2026-09-23T12:00:00Z"))
        XCTAssertEqual(parseEventTimestamp("2026-09-23T17:30:00+05:30"), date)
        XCTAssertEqual(parseEventTimestamp("2026-09-23T05:00:00-07:00"), date)
        XCTAssertEqual(parseEventTimestamp("2026-09-23T12:00:00.125Z"), date.addingTimeInterval(0.125))
        XCTAssertNotNil(parseEventTimestamp("2024-02-29T00:00:00Z"))
        XCTAssertNil(parseEventTimestamp("2026-02-29T00:00:00Z"))
        XCTAssertNil(parseEventTimestamp("2026-04-31T00:00:00Z"))
    }

    @MainActor
    func testIdentityRotationRetryPassesPreviouslyTransformedPropertiesThroughHook() async throws {
        let recorder = IdentifyHookRecorder()
        let client = makePropertiesClient(beforeSend: { event in
            var result = event
            if event.event == "$identify" {
                recorder.record(event)
                result.properties["hook_marker"] = .bool(true)
            }
            return result
        }, transport: RotationTransport())
        await client.identifyAndWait("user_42")
        _ = await client.flush()
        let seen = recorder.events
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(seen.first?.properties["hook_marker"])
        XCTAssertEqual(seen.last?.properties["hook_marker"], .bool(true))
        XCTAssertEqual(seen.last?.properties["$anon_distinct_id"], .string("12345678-1234-4abc-8abc-123456789abc"))
        let queue = try await propertiesQueue(client)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.properties["hook_marker"], .bool(true))
        XCTAssertNotEqual(seen.first?.uuid, seen.last?.uuid)
    }
}

private struct BeforeSendClock: FounderHQClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_790_164_800) } // 23 September 2026, 12:00 UTC
}

private final class IdentifyHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FounderHQEvent] = []
    var events: [FounderHQEvent] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ value: FounderHQEvent) { lock.lock(); defer { lock.unlock() }; values.append(value) }
}

private struct RotationTransport: FounderHQTransport {
    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse {
        let body = try XCTUnwrap(request.httpBody)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let batch = try XCTUnwrap(envelope["batch"] as? [[String: Any]])
        let results = Dictionary(uniqueKeysWithValues: batch.map { ($0["uuid"] as! String, ["result": "accepted"]) })
        let data = try JSONSerialization.data(withJSONObject: [
            "results": results,
            "directives": [["type": "rotate_distinct_id", "distinct_id": "12345678-1234-4abc-8abc-123456789abc"]],
        ])
        return .init(data: data, statusCode: 200)
    }
}
