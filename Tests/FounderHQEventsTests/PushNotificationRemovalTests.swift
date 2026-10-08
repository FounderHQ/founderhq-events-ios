import Foundation
import XCTest
@testable import FounderHQEvents

final class PushNotificationRemovalTests: XCTestCase {
    func testANotificationIsNamedByItsKeyItsMessageIdOrItsCollapseId() {
        let keyed: [AnyHashable: Any] = [
            "fhqOutboundMessageId": "msg_1",
            "fhqNotificationKey": "order-42",
        ]
        XCTAssertTrue(FounderHQPushRemoval.matches(identifier: "x", userInfo: keyed, key: "order-42"))
        XCTAssertTrue(FounderHQPushRemoval.matches(identifier: "x", userInfo: keyed, key: "msg_1"))
        XCTAssertFalse(FounderHQPushRemoval.matches(identifier: "x", userInfo: keyed, key: "order-43"))
        // Apple gives a push sent with a collapse id that id as its identifier.
        let plain: [AnyHashable: Any] = ["fhqOutboundMessageId": "msg_2"]
        XCTAssertTrue(FounderHQPushRemoval.matches(identifier: "order-42", userInfo: plain, key: "order-42"))
    }

    func testANotificationThatIsNotFromFounderHQIsNeverNamed() {
        XCTAssertFalse(FounderHQPushRemoval.matches(
            identifier: "order-42",
            userInfo: ["fhqNotificationKey": "order-42"],
            key: "order-42"
        ))
        XCTAssertFalse(FounderHQPushRemoval.matches(identifier: "order-42", userInfo: [:], key: "order-42"))
    }

    func testReadsTheKeysWhereExpoPutsThem() {
        let expo: [AnyHashable: Any] = [
            "body": ["fhqOutboundMessageId": "msg_1", "fhqNotificationKey": "order-42"],
        ]
        XCTAssertTrue(FounderHQPushRemoval.matches(identifier: "x", userInfo: expo, key: "order-42"))
        let expoText: [AnyHashable: Any] = [
            "body": "{\"fhqRemoveNotificationKey\":\"order-42\"}",
        ]
        XCTAssertEqual(FounderHQPushRemoval.removalKey(userInfo: expoText), "order-42")
    }

    func testOnlyASilentFounderHQPushAsksForARemoval() {
        XCTAssertEqual(
            FounderHQPushRemoval.removalKey(userInfo: [
                "fhqRemoveNotificationKey": " order-42 ",
                "aps": ["content-available": 1],
            ]),
            "order-42"
        )
        XCTAssertNil(FounderHQPushRemoval.removalKey(userInfo: ["fhqOutboundMessageId": "msg_1"]))
        XCTAssertNil(FounderHQPushRemoval.removalKey(userInfo: ["fhqRemoveNotificationKey": ""]))
    }
}
