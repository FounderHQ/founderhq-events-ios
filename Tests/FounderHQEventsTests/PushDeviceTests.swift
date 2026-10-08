import Foundation
import XCTest
@testable import FounderHQEvents

final class PushDeviceTests: XCTestCase {
    private let fcmToken = "fcm-registration-token:APA91b-example"
    private let expoToken = "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]"
    private let apnsToken = String(repeating: "a1b2c3d4e5f60718293a4b5c6d7e8f90", count: 2)

    func testRegistersTheAPNsDeviceTokenAsLowercaseHexWithWhatTheAppGave() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        let bytes = Data((0..<32).map { UInt8(($0 * 37 + 0xA1) & 0xFF) })
        await client.registerPushTokenAndWait(bytes, options: .apns(
            appId: " com.acme.app ",
            environment: .sandbox,
            enabled: true,
            permission: .provisional
        ))
        _ = await client.flush()

        let registered = try XCTUnwrap(harness.transport.events(named: "$push_device_registered").first)
        let properties = try XCTUnwrap(registered["properties"] as? [String: Any])
        let token = try XCTUnwrap(properties["$push_token"] as? String)
        XCTAssertEqual(token, bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(properties["$push_provider"] as? String, "apns")
        XCTAssertEqual(properties["$push_platform"] as? String, "ios")
        XCTAssertEqual(properties["$push_app_id"] as? String, "com.acme.app")
        XCTAssertEqual(properties["$push_environment"] as? String, "sandbox")
        XCTAssertEqual(properties["$push_enabled"] as? Bool, true)
        XCTAssertEqual(properties["$push_permission"] as? String, "provisional")
        // Device details ride the automatic properties.
        XCTAssertEqual(properties["$platform"] as? String, "ios")
        XCTAssertEqual(properties["$app_version"] as? String, "2.1.0")
        XCTAssertNotNil(properties["$device_id"])
        XCTAssertEqual(registered["distinct_id"] as? String, "person_a")
    }

    func testTheDataTokenIsAlwaysAPNsAndTheOptionsHaveOneOrder() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        // The `Data` comes from APNs, whatever the options say.
        await client.registerPushTokenAndWait(Data(repeating: 0xAB, count: 32), options: .fcm())
        // An APNs token already in hex goes through the text overload.
        await client.registerPushTokenAndWait(apnsToken.uppercased(), options: .apns())
        _ = await client.flush()
        let registrations = harness.transport.events(named: "$push_device_registered")
        XCTAssertEqual(
            registrations.map { ($0["properties"] as? [String: Any])?["$push_provider"] as? String },
            ["apns", "apns"]
        )
        XCTAssertEqual(
            (registrations.last?["properties"] as? [String: Any])?["$push_token"] as? String,
            apnsToken
        )
        XCTAssertEqual(
            FounderHQPushRegistrationOptions.apns(
                appId: "a", environment: .production, enabled: false, permission: .denied
            ),
            FounderHQPushRegistrationOptions(
                provider: .apns, appId: "a", environment: .production,
                enabled: false, permission: .denied
            )
        )
        XCTAssertEqual(FounderHQPushRegistrationOptions.fcm().provider, .fcm)
        XCTAssertEqual(FounderHQPushRegistrationOptions.expo().provider, .expo)
    }

    func testSendsOnlyWhatIsKnown() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()

        let properties = try XCTUnwrap(
            harness.transport.events(named: "$push_device_registered").first?["properties"]
                as? [String: Any]
        )
        XCTAssertEqual(properties["$push_token"] as? String, fcmToken)
        XCTAssertEqual(properties["$push_provider"] as? String, "fcm")
        // The test runner has no notification centre, and Firebase has no
        // APNs environment: neither is guessed.
        for key in ["$push_app_id", "$push_environment", "$push_enabled", "$push_permission"] {
            XCTAssertNil(properties[key], key)
        }
    }

    func testStoresTheTokenForAGuestAndSendsNothingUntilAPersonIsIdentified() async throws {
        let harness = PushHarness()
        let first = harness.client()
        await first.registerPushTokenAndWait(fcmToken, options: .fcm(appId: "com.acme.app"))
        await first.setPushEnabledAndWait(true)
        await first.close()
        XCTAssertTrue(harness.transport.pushEvents.isEmpty)
        let stored = try await storedPush(first)
        XCTAssertEqual(stored, .init(
            token: fcmToken, provider: .fcm, appId: "com.acme.app", enabled: true
        ))

        // The documented integration registers on every launch. A guest still
        // gets no device: not on a start, and not from the call.
        let second = harness.client()
        await second.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await second.flush()
        XCTAssertTrue(harness.transport.pushEvents.isEmpty)

        await second.identifyAndWait("person_a")
        await second.close()
        XCTAssertEqual(harness.transport.pushSummary(\.distinctId), [
            "$push_device_registered=person_a",
        ])
    }

    func testAppliesTheServersTokenRules() {
        for fixture in pushTokenCases {
            let result = founderHQNormalizedPushToken(fixture.token, provider: fixture.provider)
            if let stored = fixture.stored {
                XCTAssertEqual(result, .valid(stored), fixture.name)
            } else {
                guard case .invalid(let reason) = result else {
                    XCTFail("\(fixture.name) was accepted")
                    continue
                }
                XCTAssertTrue(reason.contains(fixture.provider.rawValue), fixture.name)
                let trimmed = fixture.token.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { XCTAssertFalse(reason.contains(trimmed), fixture.name) }
            }
        }
    }

    func testARefusedTokenIsNotStoredAndNotSent() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        for fixture in pushTokenCases where fixture.stored == nil {
            await client.registerPushTokenAndWait(
                fixture.token, options: .init(provider: fixture.provider)
            )
        }
        _ = await client.flush()
        XCTAssertTrue(harness.transport.pushEvents.isEmpty)
        let stored = try await storedPush(client)
        XCTAssertNil(stored)
    }

    func testTheEnumsCarryTheGeneratedProtocolValues() {
        typealias Constants = FounderHQProtocolConstants
        XCTAssertEqual(
            Set([FounderHQPushProvider.apns, .fcm, .expo].map(\.rawValue)),
            Set(Constants.pushProviders)
        )
        XCTAssertEqual(
            Set([FounderHQPushEnvironment.sandbox, .production].map(\.rawValue)),
            Set(Constants.pushEnvironments)
        )
        XCTAssertEqual(
            Set([FounderHQPushPermission.authorized, .denied, .provisional, .notDetermined]
                .map(\.rawValue)),
            Set(Constants.pushPermissions)
        )
        // A value the protocol adds must get a case here: an unknown raw value has none.
        for value in Constants.pushProviders {
            XCTAssertNotNil(FounderHQPushProvider(rawValue: value), value)
        }
        for value in Constants.pushEnvironments {
            XCTAssertNotNil(FounderHQPushEnvironment(rawValue: value), value)
        }
        for value in Constants.pushPermissions {
            XCTAssertNotNil(FounderHQPushPermission(rawValue: value), value)
        }
        XCTAssertTrue(Constants.pushPlatforms.contains(FounderHQEvents.pushPlatform))
        XCTAssertEqual(Constants.pushPayloadMessageIdKey, "fhqOutboundMessageId")
        XCTAssertEqual(Constants.pushPayloadLinkKey, "fhqLink")
    }

    func testRegistersTheStoredTokenAgainOnEveryStart() async throws {
        let harness = PushHarness()
        let first = harness.client()
        await first.identifyAndWait("person_a")
        await first.registerPushTokenAndWait(expoToken, options: .expo(appId: "@acme/app"))
        await first.close()
        XCTAssertEqual(harness.transport.events(named: "$push_device_registered").count, 1)

        for launch in 2...3 {
            let next = harness.client()
            await next.close()
            let registrations = harness.transport.events(named: "$push_device_registered")
            // An unchanged registration is sent too: it moves "last seen".
            XCTAssertEqual(registrations.count, launch)
            XCTAssertEqual(registrations.last?["distinct_id"] as? String, "person_a")
            let properties = try XCTUnwrap(registrations.last?["properties"] as? [String: Any])
            XCTAssertEqual(properties["$push_token"] as? String, expoToken)
            XCTAssertEqual(properties["$push_provider"] as? String, "expo")
            XCTAssertEqual(properties["$push_app_id"] as? String, "@acme/app")
        }
    }

    func testReplacesARefreshedToken() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.registerPushTokenAndWait(fcmToken + "-2", options: .fcm())
        _ = await client.flush()
        XCTAssertEqual(harness.transport.pushSummary(\.token), [
            "$push_device_registered=\(fcmToken)",
            "$push_device_removed=\(fcmToken)",
            "$push_device_registered=\(fcmToken)-2",
        ])
        let stored = try await storedPush(client)
        XCTAssertEqual(stored, .init(token: fcmToken + "-2", provider: .fcm))
    }

    func testRegistersTheDeviceForThePersonWhoSignsIn() async {
        let harness = PushHarness()
        let client = harness.client()
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.identifyAndWait("person_a")
        // The same person again changes nothing, so nothing is sent.
        await client.identifyAndWait("person_a")
        await client.identifyAndWait("person_b")
        _ = await client.flush()
        XCTAssertEqual(harness.transport.summary(\.distinctId), [
            "$identify=person_a",
            "$push_device_registered=person_a",
            "$identify=person_a",
            "$identify=person_b",
            "$push_device_registered=person_b",
        ])
    }

    func testResetRemovesTheDeviceFromThePersonWhoSignsOutBeforeTheIdentityRotates() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        await client.captureAndWait("left.in.the.queue")
        await client.resetAndWait()
        _ = await client.flush()

        let removed = harness.transport.events(named: "$push_device_removed")
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?["distinct_id"] as? String, "person_a")
        let properties = try XCTUnwrap(removed.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["$push_token"] as? String, fcmToken)
        XCTAssertEqual(properties["$push_provider"] as? String, "fcm")
        // A reset still drops every other queued event, as it always has.
        XCTAssertTrue(harness.transport.events(named: "left.in.the.queue").isEmpty)
        let guest = await client.getDistinctId()
        XCTAssertNotEqual(guest, "person_a")

        // A second reset has nothing left to remove.
        await client.resetAndWait()
        await client.close()
        XCTAssertEqual(harness.transport.events(named: "$push_device_removed").count, 1)

        // The token stays on the device, but the guest gets no registration:
        // not now, not on the next start, and not when the app registers again.
        let before = harness.transport.events(named: "$push_device_registered").count
        let relaunched = harness.client()
        await relaunched.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await relaunched.flush()
        XCTAssertEqual(harness.transport.events(named: "$push_device_registered").count, before)
        let stored = try await storedPush(relaunched)
        XCTAssertEqual(stored, .init(token: fcmToken, provider: .fcm))

        // The next person to sign in gets the device.
        await relaunched.identifyAndWait("person_b")
        await relaunched.close()
        let registrations = harness.transport.events(named: "$push_device_registered")
        XCTAssertEqual(registrations.count, before + 1)
        XCTAssertEqual(registrations.last?["distinct_id"] as? String, "person_b")
    }

    func testKeepsARemovalUntilTheServerAcceptsItAndSendsItFirstOnTheNextStart() async throws {
        let harness = PushHarness()
        let first = harness.client()
        await first.identifyAndWait("person_a")
        await first.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await first.flush()
        harness.transport.clear()

        // The person signs out with no network, and the app is closed.
        harness.transport.setOnline(false)
        let signedOutAt = pushTimestamp(harness.clock.now())
        await first.resetAndWait()
        await first.close()
        XCTAssertTrue(harness.transport.events.isEmpty)
        let afterLogout = try await storedPush(first)
        let pending = try XCTUnwrap(afterLogout?.pendingRemovals)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.token, fcmToken)
        XCTAssertEqual(pending.first?.provider, .fcm)
        XCTAssertEqual(pending.first?.distinctId, "person_a")
        XCTAssertEqual(pending.first?.timestamp, signedOutAt)

        // Two days later the queued copy is past its 24 hours. The list is not.
        harness.clock.advance(2 * 24 * 60 * 60)
        harness.transport.setOnline(true)
        let second = harness.client()
        await second.captureAndWait("guest.event")
        await second.identifyAndWait("person_b")
        _ = await second.flush()

        let removal = try XCTUnwrap(harness.transport.events.first)
        XCTAssertEqual(removal["event"] as? String, "$push_device_removed")
        XCTAssertEqual(removal["uuid"] as? String, pending.first?.uuid)
        XCTAssertEqual(removal["distinct_id"] as? String, "person_a")
        // It carries the time of the sign-out, not the time of this send.
        XCTAssertEqual(removal["timestamp"] as? String, signedOutAt)
        XCTAssertNotEqual(signedOutAt, pushTimestamp(harness.clock.now()))
        XCTAssertEqual(
            (removal["properties"] as? [String: Any])?["$push_token"] as? String, fcmToken
        )
        XCTAssertEqual(harness.transport.pushSummary(\.distinctId), [
            "$push_device_removed=person_a",
            "$push_device_registered=person_b",
        ])
        // Accepted: it is not kept, and it is not sent again.
        let stored = try await storedPush(second)
        XCTAssertEqual(stored, .init(token: fcmToken, provider: .fcm))
        await second.close()
        let third = harness.client()
        await third.close()
        XCTAssertEqual(harness.transport.events(named: "$push_device_removed").count, 1)
    }

    func testKeepsARemovalTheServerAskedToRetryAndAtMostTenOfThem() async throws {
        let harness = PushHarness()
        harness.transport.setResult("retry")
        let client = harness.client()
        for index in 0..<12 {
            await client.identifyAndWait("person_\(index)")
            await client.registerPushTokenAndWait(fcmToken, options: .fcm())
            await client.resetAndWait()
            _ = await client.flush()
        }
        let afterRetries = try await storedPush(client)
        let pending = try XCTUnwrap(afterRetries?.pendingRemovals)
        XCTAssertEqual(pending.map(\.distinctId), (2..<12).map { "person_\($0)" })
        await client.close()

        harness.transport.setResult("ok")
        let relaunched = harness.client()
        _ = await relaunched.flush()
        XCTAssertEqual(
            harness.transport.events(named: "$push_device_removed")
                .map { $0["distinct_id"] as? String },
            (2..<12).map { "person_\($0)" }
        )
        let stored = try await storedPush(relaunched)
        XCTAssertEqual(stored, .init(token: fcmToken, provider: .fcm))
        await relaunched.close()
    }

    func testTheSwitchTravelsWithTheRegistrationAndIsOnlyStoredBeforeOne() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.setPushEnabledAndWait(false)
        _ = await client.flush()
        XCTAssertTrue(harness.transport.pushEvents.isEmpty)
        let stored = try await storedPush(client)
        XCTAssertEqual(stored, .init(enabled: false))

        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.setPushEnabledAndWait(true)
        _ = await client.flush()
        XCTAssertEqual(
            harness.transport.events(named: "$push_device_registered").map {
                ($0["properties"] as? [String: Any])?["$push_enabled"] as? Bool
            },
            [false, true]
        )
    }

    func testDoesNotHandOnePersonsSwitchToTheNextPerson() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm(enabled: false))
        _ = await client.flush()
        await client.resetAndWait()
        let stored = try await storedPush(client)
        XCTAssertNil(stored?.enabled)
        XCTAssertEqual(stored?.token, fcmToken)

        await client.identifyAndWait("person_b")
        _ = await client.flush()
        let registrations = harness.transport.events(named: "$push_device_registered")
        XCTAssertEqual(
            registrations.map { $0["distinct_id"] as? String }, ["person_a", "person_b"]
        )
        let first = try XCTUnwrap(registrations.first?["properties"] as? [String: Any])
        let second = try XCTUnwrap(registrations.last?["properties"] as? [String: Any])
        XCTAssertEqual(first["$push_enabled"] as? Bool, false)
        // Left out, so the server default applies: push is on.
        XCTAssertNil(second["$push_enabled"])
    }

    func testUnregisterRemovesTheDeviceAndForgetsTheToken() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.unregisterPushTokenAndWait()
        await client.close()
        let removed = harness.transport.events(named: "$push_device_removed")
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?["distinct_id"] as? String, "person_a")

        let relaunched = harness.client()
        await relaunched.close()
        XCTAssertEqual(harness.transport.events(named: "$push_device_registered").count, 1)
        let stored = try await storedPush(relaunched)
        XCTAssertNil(stored)
    }

    func testOptOutHoldsRegistrationsBackButStillSendsARemoval() async {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        harness.transport.clear()

        await client.optOutAndWait()
        await client.setPushEnabledAndWait(false)
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        XCTAssertTrue(harness.transport.events.isEmpty)

        // A registration held back while opted out goes with the opt-in.
        await client.optInAndWait()
        _ = await client.flush()
        XCTAssertEqual(harness.transport.summary(\.distinctId), ["$push_device_registered=person_a"])
        harness.transport.clear()

        await client.optOutAndWait()
        await client.resetAndWait()
        _ = await client.flush()
        XCTAssertEqual(harness.transport.summary(\.distinctId), ["$push_device_removed=person_a"])
    }

    func testAQueuedRemovalSurvivesAnOptOut() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        harness.transport.clear()
        harness.transport.setOnline(false)
        await client.unregisterPushTokenAndWait()
        await client.captureAndWait("dropped.by.opt.out")
        await client.optOutAndWait()
        harness.transport.setOnline(true)
        _ = await client.flush()
        XCTAssertEqual(harness.transport.summary(\.distinctId), ["$push_device_removed=person_a"])
        let stored = try await storedPush(client)
        XCTAssertNil(stored)
    }

    func testPushDeviceEventsSkipBeforeSend() async {
        let seen = PushNames()
        let harness = PushHarness()
        let client = harness.client(beforeSend: { event in
            seen.add(event.event)
            return event.event.hasPrefix("$push_device") ? nil : event
        })
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.captureAndWait("custom")
        _ = await client.flush()
        await client.resetAndWait()
        _ = await client.flush()
        XCTAssertEqual(harness.transport.events(named: "$push_device_registered").count, 1)
        XCTAssertEqual(harness.transport.events(named: "$push_device_removed").count, 1)
        XCTAssertEqual(seen.values, ["$identify", "custom"])
    }

    func testAColdStartWithAStoredTokenStillStartsANewSessionOnTheNextRealEvent() async throws {
        let harness = PushHarness()
        let first = harness.client(captureSessions: true)
        await first.identifyAndWait("person_a")
        await first.registerPushTokenAndWait(fcmToken, options: .fcm())
        await first.close()
        let before = try await storedState(first)
        let session = try XCTUnwrap(before["sessionId"] as? String)
        harness.transport.clear()

        // A cold start two hours later: the stored session has expired.
        harness.clock.advance(2 * 60 * 60)
        let second = harness.client(captureSessions: true)
        _ = await second.flush()
        // The start registers the device and that is all it does: no session
        // rotates, and nothing counts as activity.
        XCTAssertEqual(harness.transport.summary(\.sessionId), [
            "$push_device_registered=\(session)",
        ])
        let after = try await storedState(second)
        XCTAssertEqual(after["sessionId"] as? String, session)
        XCTAssertEqual(after["lastActivityAt"] as? Double, before["lastActivityAt"] as? Double)

        await second.captureAndWait("real.event")
        _ = await second.flush()
        let sent = harness.transport.events.dropFirst()
        XCTAssertEqual(sent.map { $0["event"] as? String }, ["$session_start", "real.event"])
        let started = try XCTUnwrap(sent.first?["session_id"] as? String)
        XCTAssertNotEqual(started, session)
        XCTAssertEqual(sent.last?["session_id"] as? String, started)
        await second.close()
    }

    func testAPushDeviceEventDoesNotKeepASessionAlive() async throws {
        let harness = PushHarness()
        let client = harness.client(captureSessions: true)
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        await client.captureAndWait("first.event")
        let state = try await storedState(client)
        let session = try XCTUnwrap(state["sessionId"] as? String)

        // Twenty minutes of nothing, a push switch, then twenty more minutes.
        harness.clock.advance(20 * 60)
        await client.setPushEnabledAndWait(true)
        harness.clock.advance(20 * 60)
        await client.captureAndWait("second.event")
        _ = await client.flush()

        XCTAssertEqual(
            harness.transport.events(named: "first.event").first?["session_id"] as? String, session
        )
        XCTAssertEqual(
            harness.transport.events(named: "$push_device_registered")
                .map { $0["session_id"] as? String },
            [session, session]
        )
        // Forty minutes passed since the person last did something.
        let starts = harness.transport.events(named: "$session_start")
        XCTAssertEqual(starts.count, 2)
        let second = harness.transport.events(named: "second.event").first?["session_id"] as? String
        XCTAssertNotEqual(second, session)
        XCTAssertEqual(second, starts.last?["session_id"] as? String)
        await client.close()
    }

    func testAnOpenCarriesTheMessageIdAndHandsBackTheLink() async throws {
        let opened = PushNames()
        let harness = PushHarness()
        let client = harness.client(onPushNotificationOpened: { payload in
            opened.add("\(payload.messageId ?? "-")|\(payload.link ?? "-")")
        })
        let link = await MainActor.run {
            client.capturePushNotificationOpened(userInfo: [
                "fhqOutboundMessageId": "msg_123",
                "fhqLink": "acme://orders/42",
                "aps": ["alert": ["title": "Your order shipped", "body": "never sent"]],
                "secret": "never sent",
            ], properties: ["campaign": "shipping"])
        }
        let linkOnly = await MainActor.run {
            client.capturePushNotificationOpened(userInfo: ["fhqLink": "acme://home"])
        }
        await client.readyForCapture()
        _ = await client.flush()

        XCTAssertEqual(link, "acme://orders/42")
        XCTAssertEqual(linkOnly, "acme://home")
        XCTAssertEqual(opened.values, ["msg_123|acme://orders/42", "-|acme://home"])
        let events = harness.transport.events(named: "$push_notification_opened")
        XCTAssertEqual(events.count, 2)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["$push_message_id"] as? String, "msg_123")
        XCTAssertEqual(properties["campaign"] as? String, "shipping")
        XCTAssertNil(properties["fhqLink"])
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        XCTAssertFalse(wire.contains("never sent"))
        XCTAssertFalse(wire.contains("acme://orders/42"))
        XCTAssertNil((events.last?["properties"] as? [String: Any])?["$push_message_id"])
        XCTAssertEqual(
            FounderHQPushPayload(userInfo: ["fhqOutboundMessageId": 7, "fhqLink": "  "]),
            FounderHQPushPayload(userInfo: [:])
        )
    }

    func testAManualReportSendsNothingForANotificationThatIsNotFromFounderHQ() async {
        let opened = PushNames()
        let harness = PushHarness()
        let client = harness.client(onPushNotificationOpened: { _ in opened.add("called") })
        let results = await MainActor.run {
            [
                client.capturePushNotificationOpened(userInfo: [:]),
                client.capturePushNotificationOpened(userInfo: [
                    "aps": ["alert": "Another service sent this"],
                    "link": "acme://not-ours",
                    "fhqLink": "   ",
                ], properties: ["campaign": "other"]),
            ]
        }
        await client.readyForCapture()
        _ = await client.flush()
        XCTAssertEqual(results, [nil, nil])
        XCTAssertTrue(opened.values.isEmpty)
        XCTAssertTrue(harness.transport.events(named: "$push_notification_opened").isEmpty)
    }

    func testAManualReportDoesNothingWhileTheSDKReportsOpensItself() async {
        let opened = PushNames()
        let harness = PushHarness()
        let client = harness.client(
            capturePushNotificationOpened: true,
            onPushNotificationOpened: { _ in opened.add("called") }
        )
        let link = await MainActor.run {
            client.capturePushNotificationOpened(userInfo: [
                "fhqOutboundMessageId": "msg_123", "fhqLink": "acme://orders/42",
            ])
        }
        await client.readyForCapture()
        _ = await client.flush()
        // The link is only read. The automatic report is the one report.
        XCTAssertEqual(link, "acme://orders/42")
        XCTAssertTrue(opened.values.isEmpty)
        XCTAssertTrue(harness.transport.events(named: "$push_notification_opened").isEmpty)
    }

    func testReadsThePayloadThatExpoDelivers() throws {
        let expected = FounderHQPushPayload(userInfo: [
            "fhqOutboundMessageId": "msg_123", "fhqLink": "acme://orders/42",
        ])
        // Expo puts the data of the app under `body`: a dictionary...
        XCTAssertEqual(FounderHQPushPayload(userInfo: [
            "aps": ["alert": ["title": "Shipped"]],
            "experienceId": "@acme/app",
            "body": ["fhqOutboundMessageId": "msg_123", "fhqLink": "acme://orders/42"],
        ]), expected)
        // ...or the same as JSON text.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: [
            "fhqOutboundMessageId": "msg_123", "fhqLink": "acme://orders/42",
        ]), as: UTF8.self)
        XCTAssertEqual(FounderHQPushPayload(userInfo: ["body": text]), expected)
        // A key at the top level wins, and each key is read by itself.
        XCTAssertEqual(FounderHQPushPayload(userInfo: [
            "fhqOutboundMessageId": "msg_top",
            "body": ["fhqOutboundMessageId": "msg_body", "fhqLink": "acme://orders/42"],
        ]), FounderHQPushPayload(userInfo: [
            "fhqOutboundMessageId": "msg_top", "fhqLink": "acme://orders/42",
        ]))
        // A `body` that is plain text, or JSON that is no object, says nothing.
        for body in ["Your order shipped", "[1, 2]", "{broken"] as [Any] {
            XCTAssertEqual(
                FounderHQPushPayload(userInfo: ["body": body]),
                FounderHQPushPayload(userInfo: [:])
            )
        }
    }

    func testAPersonChangeWithoutAResetDoesNotKeepThePushSwitch() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm(enabled: false))
        // No reset(): the app identifies the next person directly.
        await client.identifyAndWait("person_b")
        _ = await client.flush()
        let registrations = harness.transport.events(named: "$push_device_registered")
        XCTAssertEqual(
            registrations.map { $0["distinct_id"] as? String }, ["person_a", "person_b"]
        )
        XCTAssertEqual(
            registrations.map { ($0["properties"] as? [String: Any])?["$push_enabled"] as? Bool },
            [false, nil]
        )
        let stored = try await storedPush(client)
        XCTAssertEqual(stored, .init(token: fcmToken, provider: .fcm))

        // The same person again keeps the switch.
        await client.setPushEnabledAndWait(false)
        await client.identifyAndWait("person_b")
        let kept = try await storedPush(client)
        XCTAssertEqual(kept?.enabled, false)
    }

    func testASignInAgainDropsTheRemovalThatStillWaits() async throws {
        for optsOut in [false, true] {
            let harness = PushHarness()
            let first = harness.client()
            await first.identifyAndWait("person_a")
            await first.registerPushTokenAndWait(fcmToken, options: .fcm())
            _ = await first.flush()
            harness.transport.clear()

            // The person signs out with no network, and signs in again.
            harness.transport.setOnline(false)
            await first.resetAndWait()
            let afterLogout = try await storedPush(first)
            XCTAssertEqual(afterLogout?.pendingRemovals?.map(\.distinctId), ["person_a"])
            await first.identifyAndWait("person_a")
            if optsOut { await first.optOutAndWait() }
            await first.close()
            let afterLogin = try await storedPush(first)
            XCTAssertEqual(afterLogin, .init(token: fcmToken, provider: .fcm), "\(optsOut)")

            // The app starts again, online. The device stays with the person.
            harness.transport.setOnline(true)
            let second = harness.client()
            await second.registerPushTokenAndWait(fcmToken, options: .fcm())
            await second.close()
            XCTAssertTrue(
                harness.transport.events(named: "$push_device_removed").isEmpty, "\(optsOut)"
            )
            // An opted-out person sends no registration that could undo a removal.
            XCTAssertEqual(
                Set(harness.transport.pushSummary(\.distinctId)),
                optsOut ? [] : ["$push_device_registered=person_a"],
                "\(optsOut)"
            )
            let afterRestart = try await storedPush(second)
            XCTAssertEqual(afterRestart, .init(token: fcmToken, provider: .fcm), "\(optsOut)")
        }
    }

    func testASignInOfAnotherPersonKeepsTheRemoval() async throws {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        harness.transport.clear()
        harness.transport.setOnline(false)
        await client.resetAndWait()
        await client.identifyAndWait("person_b")
        harness.transport.setOnline(true)
        _ = await client.flush()
        XCTAssertEqual(harness.transport.pushSummary(\.distinctId), [
            "$push_device_removed=person_a",
            "$push_device_registered=person_b",
        ])
    }

    func testSendsOneRegistrationInAStart() async throws {
        let harness = PushHarness()
        let first = harness.client()
        await first.identifyAndWait("person_a")
        await first.registerPushTokenAndWait(fcmToken, options: .fcm())
        // The same call again changes nothing, so nothing is sent.
        await first.registerPushTokenAndWait(fcmToken, options: .fcm())
        await first.close()
        XCTAssertEqual(harness.transport.events(named: "$push_device_registered").count, 1)

        // The documented integration registers on every launch. The start
        // sends one registration, and the call of the app does not add one.
        for launch in 2...3 {
            let next = harness.client()
            await next.registerPushTokenAndWait(fcmToken, options: .fcm())
            await next.close()
            XCTAssertEqual(
                harness.transport.events(named: "$push_device_registered").count, launch
            )
        }

        // A value that changed is sent.
        let last = harness.client()
        await last.readyForCapture()
        await last.registerPushTokenAndWait(fcmToken, options: .fcm(enabled: false))
        await last.registerPushTokenAndWait(fcmToken, options: .fcm(permission: .denied))
        await last.close()
        let registrations = harness.transport.events(named: "$push_device_registered")
        XCTAssertEqual(registrations.count, 6)
        let properties = try XCTUnwrap(registrations.last?["properties"] as? [String: Any])
        XCTAssertEqual(properties["$push_enabled"] as? Bool, false)
        XCTAssertEqual(properties["$push_permission"] as? String, "denied")
    }

    func testARegistrationThatAnOptOutDroppedIsSentAfterTheOptIn() async {
        let harness = PushHarness()
        let client = harness.client()
        await client.identifyAndWait("person_a")
        _ = await client.flush()
        harness.transport.clear()
        harness.transport.setOnline(false)
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        // The opt-out empties the queue, and the registration with it.
        await client.optOutAndWait()
        harness.transport.setOnline(true)
        await client.optInAndWait()
        _ = await client.flush()
        XCTAssertEqual(harness.transport.pushSummary(\.distinctId), [
            "$push_device_registered=person_a",
        ])
    }

    func testAFullQueueCutsOtherEventsBeforeARemoval() async throws {
        let harness = PushHarness()
        let client = harness.client(maxQueueSize: 3)
        await client.identifyAndWait("person_a")
        await client.registerPushTokenAndWait(fcmToken, options: .fcm())
        _ = await client.flush()
        harness.transport.clear()

        harness.transport.setOnline(false)
        await client.resetAndWait()
        for index in 1...6 { await client.captureAndWait("event.\(index)") }
        harness.transport.setOnline(true)
        _ = await client.flush()
        // The removal is the oldest event in the queue, and it is the one kept.
        XCTAssertEqual(harness.transport.events.map { $0["event"] as? String }, [
            "$push_device_removed", "event.5", "event.6",
        ])
    }

    func testAPushStateThisBuildCannotReadIsDroppedAlone() async throws {
        let stateKey = "com.founderhq.events.v2.fhq_pk_push"
        let unreadable: [Any] = [
            // A provider a later build added.
            [
                "token": "https://push.example/subscription", "provider": "web_push",
                "environment": "staging", "enabled": true,
                "pendingRemovals": [
                    ["uuid": "0d3f0d5e-7c53-4a3c-9a0f-1f2e3d4c5b6a", "token": fcmToken,
                     "provider": "fcm", "distinctId": "person_x"],
                    ["uuid": "1d3f0d5e-7c53-4a3c-9a0f-1f2e3d4c5b6a", "token": "x",
                     "provider": "web_push", "distinctId": "person_y"],
                ],
            ] as [String: Any],
            // Not a push state at all.
            "nonsense",
        ]
        for push in unreadable {
            let harness = PushHarness()
            harness.transport.setOnline(false)
            let first = harness.client()
            await first.identifyAndWait("person_a")
            await first.captureAndWait("kept.event")
            await first.close()
            var state = try await storedState(first)
            state["push"] = push
            harness.storage.set(try JSONSerialization.data(withJSONObject: state), forKey: stateKey)

            harness.transport.setOnline(true)
            let second = harness.client()
            _ = await second.flush()
            // The identity and the queue are still there.
            let distinctId = await second.getDistinctId()
            XCTAssertEqual(distinctId, "person_a")
            XCTAssertEqual(
                harness.transport.events(named: "kept.event").first?["distinct_id"] as? String,
                "person_a"
            )
            XCTAssertTrue(harness.transport.events(named: "$push_device_registered").isEmpty)
            let stored = try await storedPush(second)
            if push is String {
                XCTAssertNil(stored)
                XCTAssertTrue(harness.transport.pushEvents.isEmpty)
            } else {
                // The switch and the removal it can read are kept.
                XCTAssertEqual(stored, .init(enabled: true))
                XCTAssertEqual(harness.transport.pushSummary(\.distinctId), [
                    "$push_device_removed=person_x",
                ])
            }
            await second.close()
        }
    }

    func testReadsAStateAnEarlierBuildOfThisBranchWrote() async throws {
        let harness = PushHarness()
        let first = harness.client()
        await first.identifyAndWait("person_a")
        await first.close()
        // The earlier shape: an `attached` flag and no `pendingRemovals`.
        var state = try await storedState(first)
        state["push"] = [
            "token": fcmToken, "provider": "fcm", "enabled": false, "attached": true,
        ] as [String: Any]
        harness.storage.set(
            try JSONSerialization.data(withJSONObject: state),
            forKey: "com.founderhq.events.v2.fhq_pk_push"
        )

        let second = harness.client()
        await second.close()
        let properties = try XCTUnwrap(
            harness.transport.events(named: "$push_device_registered").first?["properties"]
                as? [String: Any]
        )
        XCTAssertEqual(properties["$push_token"] as? String, fcmToken)
        XCTAssertEqual(properties["$push_enabled"] as? Bool, false)
        let stored = try await storedPush(second)
        XCTAssertEqual(stored, .init(token: fcmToken, provider: .fcm, enabled: false))
    }

    func testReadsTheAPNsEnvironmentFromAProvisioningProfile() {
        func profile(_ entitlements: String) -> Data {
            // A real profile wraps the plist in a signed container.
            Data([0x30, 0x82, 0x01, 0xFF]) + Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
            """.utf8) + Data([0xA0, 0x82, 0x00])
        }
        typealias Detector = FounderHQPushEnvironmentDetector
        XCTAssertEqual(Detector.environment(
            provisioningProfile: profile("<key>aps-environment</key><string>development</string>")
        ), .sandbox)
        XCTAssertEqual(Detector.environment(
            provisioningProfile: profile("<key>aps-environment</key><string>production</string>")
        ), .production)
        XCTAssertEqual(Detector.environment(provisioningProfile: profile(
            "<key>com.apple.developer.aps-environment</key><string>development</string>"
        )), .sandbox)
        // A profile without the push entitlement, or bytes that are no profile, say nothing.
        XCTAssertNil(Detector.environment(
            provisioningProfile: profile("<key>get-task-allow</key><true/>")
        ))
        XCTAssertNil(Detector.environment(provisioningProfile: Data("not a profile".utf8)))
    }

    func testMapsTheSystemPermission() {
        XCTAssertEqual(founderHQPushPermission(authorizationStatus: 0), .notDetermined)
        XCTAssertEqual(founderHQPushPermission(authorizationStatus: 1), .denied)
        XCTAssertEqual(founderHQPushPermission(authorizationStatus: 2), .authorized)
        XCTAssertEqual(founderHQPushPermission(authorizationStatus: 3), .provisional)
        XCTAssertEqual(founderHQPushPermission(authorizationStatus: 4), .authorized)
        XCTAssertNil(founderHQPushPermission(authorizationStatus: 99))
        XCTAssertEqual(FounderHQPushPermission.notDetermined.rawValue, "not_determined")
    }

    private func pushTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func storedState(_ client: FounderHQEvents) async throws -> [String: Any] {
        let persisted = await client.persistedStateData()
        let data = try XCTUnwrap(persisted)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func storedPush(_ client: FounderHQEvents) async throws -> FounderHQPushDeviceState? {
        guard let push = try await storedState(client)["push"] else { return nil }
        return try JSONDecoder().decode(
            FounderHQPushDeviceState.self,
            from: try JSONSerialization.data(withJSONObject: push)
        )
    }
}

private struct PushTokenCase {
    let name: String
    let provider: FounderHQPushProvider
    let token: String
    /// What the SDK keeps and sends; nil means refused.
    let stored: String?

    init(_ name: String, _ provider: FounderHQPushProvider, _ token: String, _ stored: String?) {
        self.name = name
        self.provider = provider
        self.token = token
        self.stored = stored
    }
}

private let hex64 = String(repeating: "0123456789abcdef", count: 4)

/**
 The server's token rules as cases. The canonical rules are
 `normalizePushToken` in apps/web/src/lib/comms/push-devices.ts. The same
 table is in the Android suite (FounderHQPushDeviceTest.kt) and the React
 Native suite (push.test.ts): change the three together with the server.
 */
private let pushTokenCases: [PushTokenCase] = [
    .init("apns 64 hex", .apns, hex64, hex64),
    .init("apns uppercase hex is stored lowercase", .apns, hex64.uppercased(), hex64),
    .init("apns 200 hex", .apns, String(repeating: "ab", count: 100), String(repeating: "ab", count: 100)),
    .init("apns is trimmed", .apns, "  \(hex64)\n", hex64),
    .init("apns 63 hex", .apns, String(hex64.dropFirst()), nil),
    .init("apns 201 hex", .apns, String(repeating: "a", count: 201), nil),
    .init("apns with a letter that is not hex", .apns, "g" + hex64.dropFirst(), nil),
    .init("apns given a Firebase token", .apns, "fcm-registration-token:APA91b-example", nil),
    .init("expo ExponentPushToken", .expo, "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]", "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]"),
    .init("expo ExpoPushToken", .expo, "ExpoPushToken[abc-123_XYZ]", "ExpoPushToken[abc-123_XYZ]"),
    .init("expo with empty brackets", .expo, "ExponentPushToken[]", nil),
    .init("expo with no closing bracket", .expo, "ExponentPushToken[abcdef", nil),
    .init("expo with a bracket inside", .expo, "ExponentPushToken[ab[c]d]", nil),
    .init("expo with a space inside", .expo, "ExponentPushToken[ab cd]", nil),
    .init("expo with text after the bracket", .expo, "ExponentPushToken[abcd]x", nil),
    .init("expo with another prefix", .expo, "PushToken[abcdefgh]", nil),
    .init("expo given bare hex", .expo, hex64, nil),
    .init("fcm 8 characters", .fcm, "abcd1234", "abcd1234"),
    .init("fcm 4096 characters", .fcm, String(repeating: "f", count: 4096), String(repeating: "f", count: 4096)),
    .init("fcm keeps its case and punctuation", .fcm, "dQw4:APA91b-Example_Token", "dQw4:APA91b-Example_Token"),
    .init("fcm is trimmed", .fcm, " abcd1234 ", "abcd1234"),
    .init("fcm 7 characters", .fcm, "abcd123", nil),
    .init("fcm 4097 characters", .fcm, String(repeating: "f", count: 4097), nil),
    .init("fcm with a space inside", .fcm, "abcd 1234", nil),
    .init("fcm with a tab inside", .fcm, "abcd\t1234", nil),
    .init("fcm with a line break inside", .fcm, "abcd\n1234", nil),
    .init("fcm empty", .fcm, "", nil),
]

/// One storage, one transport, and one clock, shared by every client a test starts.
private final class PushHarness: @unchecked Sendable {
    let storage = PushStorage()
    let transport = PushTransport()
    let clock = PushClock()

    func client(
        captureSessions: Bool = false,
        maxQueueSize: Int = 1_000,
        capturePushNotificationOpened: Bool = false,
        beforeSend: FounderHQBeforeSend? = nil,
        onPushNotificationOpened: FounderHQPushOpenedHandler? = nil
    ) -> FounderHQEvents {
        FounderHQEvents(apiKey: "fhq_pk_push", configuration: .init(
            flushAt: 1_000, flushInterval: 0, captureLifecycle: false, captureScreens: false,
            captureSessions: captureSessions, captureInstallUpdates: false, remoteConfig: false,
            maxQueueSize: maxQueueSize,
            capturePushNotificationOpened: capturePushNotificationOpened, beforeSend: beforeSend,
            onPushNotificationOpened: onPushNotificationOpened
        ), dependencies: .init(
            clock: clock, storage: storage, transport: transport,
            platformFacts: PushFacts(), screenCapture: PropertiesScreens()
        ))
    }
}

private final class PushClock: FounderHQClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_786_694_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private struct PushFacts: FounderHQPlatformFactsProvider {
    func properties() -> JSONObject { ["$app_version": .string("2.1.0")] }
}

private final class PushNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return names }
    func add(_ name: String) { lock.lock(); defer { lock.unlock() }; names.append(name) }
}

private final class PushStorage: FounderHQStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return dataValues[key] }
    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return stringValues[key] }
    func set(_ data: Data?, forKey key: String) { lock.lock(); defer { lock.unlock() }; dataValues[key] = data }
    func set(_ value: String?, forKey key: String) { lock.lock(); defer { lock.unlock() }; stringValues[key] = value }
}

/// Answers every batch while online and keeps each accepted event in the order it left.
private final class PushTransport: FounderHQTransport, @unchecked Sendable {
    struct Sent { let name: String; let distinctId: String; let token: String; let sessionId: String }
    private let lock = NSLock()
    private var sent: [[String: Any]] = []
    private var online = true
    /// What ingest answers for every event: "ok" or "retry".
    private var result = "ok"

    var events: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
    var pushEvents: [[String: Any]] {
        events.filter { ($0["event"] as? String ?? "").hasPrefix("$push_device") }
    }
    func events(named name: String) -> [[String: Any]] {
        events.filter { $0["event"] as? String == name }
    }
    func summary(_ field: KeyPath<Sent, String>) -> [String] { Self.summary(events, field) }
    func pushSummary(_ field: KeyPath<Sent, String>) -> [String] { Self.summary(pushEvents, field) }
    private static func summary(_ events: [[String: Any]], _ field: KeyPath<Sent, String>) -> [String] {
        events.map { event in
            let entry = Sent(
                name: event["event"] as? String ?? "",
                distinctId: event["distinct_id"] as? String ?? "",
                token: (event["properties"] as? [String: Any])?["$push_token"] as? String ?? "",
                sessionId: event["session_id"] as? String ?? ""
            )
            return "\(entry.name)=\(entry[keyPath: field])"
        }
    }
    func clear() { lock.lock(); defer { lock.unlock() }; sent = [] }
    func setOnline(_ value: Bool) { lock.lock(); defer { lock.unlock() }; online = value }
    func setResult(_ value: String) { lock.lock(); defer { lock.unlock() }; result = value }

    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let batch = body?["batch"] as? [[String: Any]] ?? []
        let answer: String? = {
            lock.lock(); defer { lock.unlock() }
            guard online else { return nil }
            if result == "ok" { sent.append(contentsOf: batch) }
            return result
        }()
        guard let answer else { throw URLError(.notConnectedToInternet) }
        let results = Dictionary(uniqueKeysWithValues: batch.map {
            ($0["uuid"] as? String ?? "", ["result": answer])
        })
        return .init(
            data: try JSONSerialization.data(withJSONObject: ["results": results]),
            statusCode: 202
        )
    }
}

// The harness is private to this file, so the removal tests that need a
// client live here; the pure ones are in PushNotificationRemovalTests.swift.
extension PushDeviceTests {
    func testEveryOtherPushIsLeftToTheApp() {
        let client = PushHarness().client()
        XCTAssertFalse(client.handleRemoteNotification(userInfo: ["aps": ["content-available": 1]]))
    }

    func testARemovalInAProcessThatIsNotAnAppStillAnswers() {
        let client = PushHarness().client()
        let answered = expectation(description: "completion")
        XCTAssertTrue(client.handleRemoteNotification(
            userInfo: ["fhqRemoveNotificationKey": "order-42"],
            completion: { answered.fulfill() }
        ))
        wait(for: [answered], timeout: 2)
    }
}

