import Foundation
import CoreFoundation
import XCTest
@testable import FounderHQEvents

final class ProtocolTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object(["plan": .string("pro"), "count": .number(2)])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testProductionUUIDv7GeneratorSetsVersionAndVariant() {
        let provider = FounderHQSystemUUIDProvider()
        for offset in 0..<100 {
            let value = provider.uuidV7(at: Date(timeIntervalSince1970: 1_785_542_400 + Double(offset)))
            XCTAssertTrue(isTestUUIDv7(value), value)
        }
    }

    func testTransportConfigInstallsScreensFromInitiallyDisabledState() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_785_542_400))
        let storage = TestStorage()
        let transport = TestTransport()
        transport.nextRemoteConfig = ["capture_screens": true]
        let installer = TestScreenCaptureInstaller()
        let client = FounderHQEvents(
            apiKey: "fhq_pk_remote",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false
            ),
            dependencies: .init(
                clock: clock,
                uuid: TestUUIDProvider(
                    uuids: ["00000000-0000-4000-8000-000000000001"],
                    sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
                ),
                storage: storage,
                transport: transport,
                platformFacts: TestFacts(values: [:]),
                screenCapture: installer
            )
        )

        await client.readyForCapture()

        XCTAssertEqual(transport.configRequests.count, 1)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(
            storage.string(forKey: "com.founderhq.events.config.v1.fhq_pk_remote"),
            "{\"capture_screens\":true}"
        )
    }

    func testRevenueCatPurchaseIdentitySurvivesIdentifyAndReinstallThenRotatesWithLogIn() async {
        let storage = TestStorage()
        let revenueCat = TestRevenueCatIdentity()
        let uuids = TestUUIDProvider(
            uuids: (1...24).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
            sessionIds: (1...4).map { "01989f2e-7800-7000-8000-\(String(format: "%012d", $0))" }
        )
        let dependencies = FounderHQEventsDependencies(
            clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
            uuid: uuids,
            storage: storage,
            transport: TestTransport(),
            platformFacts: TestFacts(values: [:])
        )
        let configuration = FounderHQEventsConfiguration(
            flushInterval: 0,
            captureLifecycle: false,
            captureScreens: false,
            captureSessions: false,
            captureInstallUpdates: false,
            remoteConfig: false
        )
        let firstInstall = FounderHQEvents(
            apiKey: "fhq_pk_revenuecat",
            configuration: configuration,
            dependencies: dependencies,
            revenueCatIdentity: revenueCat
        )
        await firstInstall.readyForCapture()
        let initial = await firstInstall.purchaseAttribution()
        XCTAssertEqual(initial.appAccountToken.uuidString.lowercased(), initial.obfuscatedExternalAccountId)
        XCTAssertEqual(initial.revenueCatAppUserID, initial.obfuscatedExternalAccountId)

        await firstInstall.identifyAndWait("account-a")
        var calls = await revenueCat.snapshot()
        XCTAssertEqual(calls.configured.last, initial.revenueCatAppUserID)
        XCTAssertEqual(calls.loggedIn.last, initial.revenueCatAppUserID)

        let reinstall = FounderHQEvents(
            apiKey: "fhq_pk_revenuecat",
            configuration: configuration,
            dependencies: dependencies,
            revenueCatIdentity: revenueCat
        )
        await reinstall.readyForCapture()
        let restored = await reinstall.purchaseAttribution()
        XCTAssertEqual(restored, initial)

        await reinstall.identifyAndWait("account-b")
        let switched = await reinstall.purchaseAttribution()
        XCTAssertNotEqual(switched, initial)
        calls = await revenueCat.snapshot()
        XCTAssertEqual(calls.loggedIn.last, switched.revenueCatAppUserID)

        await reinstall.resetAndWait()
        let reset = await reinstall.purchaseAttribution()
        XCTAssertNotEqual(reset, switched)
        calls = await revenueCat.snapshot()
        XCTAssertEqual(calls.configured, [initial.revenueCatAppUserID, initial.revenueCatAppUserID])
        XCTAssertEqual(calls.loggedIn, [
            initial.revenueCatAppUserID,
            switched.revenueCatAppUserID,
            reset.revenueCatAppUserID,
        ])
    }

    func testIdentifyRejectsReservedAndOversizedIdsWithoutChangingIdentity() async {
        let client = FounderHQEvents(
            apiKey: "fhq_pk_identity_validation",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false
            ),
            dependencies: .init(
                clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
                uuid: TestUUIDProvider(
                    uuids: (1...8).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
                ),
                storage: TestStorage(),
                transport: TestTransport(),
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.identifyAndWait("customer-1")
        await client.identifyAndWait(" [object Object] ")
        await client.identifyAndWait(String(repeating: "x", count: 401))

        let distinctId = await client.getDistinctId()
        XCTAssertEqual(distinctId, "customer-1")
    }

    func testOfflineQueueAppliesSizeAndAgeCaps() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_694_000))
        let client = FounderHQEvents(
            apiKey: "fhq_pk_queue_caps",
            configuration: .init(
                flushAt: 100,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                maxQueueSize: 2,
                eventTTL: 60
            ),
            dependencies: .init(
                clock: clock,
                uuid: TestUUIDProvider(
                    uuids: (1...8).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
                ),
                storage: TestStorage(),
                transport: TestTransport(),
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.captureAndWait("first")
        await client.captureAndWait("second")
        await client.captureAndWait("third")
        clock.value.addTimeInterval(61)
        await client.captureAndWait("fresh")

        let persistedStateData = await client.persistedStateData()
        let data = try XCTUnwrap(persistedStateData)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let queue = try XCTUnwrap(persisted["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.compactMap { $0["event"] as? String }, ["fresh"])
    }

    /// `maxRetries: 2` keeps the first two rungs, so the ladder is 30s, 30s, stop.
    /**
     A manual `flush()` means "send now", so it ignores the ladder and takes
     waiting events with it. Only the flushes the SDK schedules for itself
     wait, which is why every ladder test below drives `flushOnSchedule()`.
     Android draws the same line.
     */
    func testAManualFlushIgnoresTheLadderAndSendsWaitingEvents() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_760_000_000))
        let transport = TestTransport()
        transport.online = false
        let client = FounderHQEvents(
            apiKey: "fhq_pk_manualflush",
            configuration: .init(
                flushAt: 100,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false
            ),
            dependencies: .init(
                clock: clock,
                uuid: TestUUIDProvider(
                    uuids: (1...8).map {
                        "20000000-0000-4000-8000-\(String(format: "%012d", $0))"
                    },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000002"]
                ),
                storage: TestStorage(),
                transport: transport,
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.captureAndWait("ladder.manual")
        _ = await client.flushOnSchedule()
        // That attempt failed, so the event now waits 30s on the first rung.
        transport.requests.removeAll()
        transport.online = true

        _ = await client.flushOnSchedule()
        XCTAssertTrue(
            transport.requests.isEmpty,
            "a scheduled flush must leave a waiting event alone"
        )

        _ = await client.flush()
        XCTAssertFalse(
            transport.requests.isEmpty,
            "a manual flush means send now, ladder or not"
        )
    }

    func testATruncatedLadderWaitsItsTwoRungsAndThenGivesUp() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_694_000))
        let transport = TestTransport()
        transport.online = false
        let client = FounderHQEvents(
            apiKey: "fhq_pk_retries",
            configuration: .init(
                flushAt: 100,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                maxRetries: 2
            ),
            dependencies: .init(
                clock: clock,
                uuid: TestUUIDProvider(
                    uuids: (1...8).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
                ),
                storage: TestStorage(),
                transport: transport,
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.captureAndWait("retry.me")

        // The first attempt goes out at once and fails.
        var flushed = await client.flushOnSchedule()
        XCTAssertFalse(flushed)
        XCTAssertEqual(transport.eventRequests.count, 1)

        // A flush inside the 30 second wait skips the event instead of
        // spending one of its attempts on it.
        flushed = await client.flushOnSchedule()
        XCTAssertTrue(flushed)
        XCTAssertEqual(transport.eventRequests.count, 1)
        let queuedNow1 = try await queuedEvents(of: client)
        XCTAssertEqual(queuedNow1, ["retry.me"])

        clock.value.addTimeInterval(30)
        flushed = await client.flushOnSchedule()
        XCTAssertFalse(flushed)
        XCTAssertEqual(transport.eventRequests.count, 2)
        let queuedNow2 = try await queuedEvents(of: client)
        XCTAssertEqual(queuedNow2, ["retry.me"])

        clock.value.addTimeInterval(30)
        flushed = await client.flushOnSchedule()
        XCTAssertFalse(flushed)
        XCTAssertEqual(transport.eventRequests.count, 3)
        let queuedNow3 = try await queuedEvents(of: client)
        XCTAssertEqual(queuedNow3, [String]())

        clock.value.addTimeInterval(30)
        _ = await client.flushOnSchedule()
        XCTAssertEqual(transport.eventRequests.count, 3)
    }

    /**
     The whole ladder: send now, wait 30s, 30s, 2min, 5min, and then one last
     attempt that only a new process releases.
     */
    func testTheFullLadderWaitsEachRungAndKeepsItsLastOneForTheNextLaunch() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_694_000))
        let storage = TestStorage()
        let transport = TestTransport()
        transport.online = false
        let configuration = FounderHQEventsConfiguration(
            flushAt: 100,
            flushInterval: 0,
            captureLifecycle: false,
            captureScreens: false,
            captureSessions: false,
            captureInstallUpdates: false,
            remoteConfig: false
        )
        XCTAssertEqual(configuration.maxRetries, 5)
        let dependencies = FounderHQEventsDependencies(
            clock: clock,
            uuid: TestUUIDProvider(
                uuids: (1...8).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
                sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
            ),
            storage: storage,
            transport: transport,
            platformFacts: TestFacts(values: [:])
        )
        let client = FounderHQEvents(
            apiKey: "fhq_pk_ladder",
            configuration: configuration,
            dependencies: dependencies
        )
        await client.captureAndWait("ladder.me")

        // Rung by rung: a flush one second early changes nothing, and a flush
        // on time spends exactly one attempt.
        for wait in [0, 30, 30, 120, 300] {
            if wait > 0 {
                clock.value.addTimeInterval(TimeInterval(wait) - 1)
                let early = await client.flushOnSchedule()
                XCTAssertTrue(early, "a flush inside the \(wait)s rung must skip the event")
                clock.value.addTimeInterval(1)
            }
            let onTime = await client.flushOnSchedule()
            XCTAssertFalse(onTime)
        }
        XCTAssertEqual(transport.eventRequests.count, 5)

        // The last rung answers to a launch, not to a clock.
        clock.value.addTimeInterval(60 * 60)
        let stalled = await client.flushOnSchedule()
        XCTAssertTrue(stalled)
        XCTAssertEqual(transport.eventRequests.count, 5)
        let queuedNow4 = try await queuedEvents(of: client)
        XCTAssertEqual(queuedNow4, ["ladder.me"])

        let relaunched = FounderHQEvents(
            apiKey: "fhq_pk_ladder",
            configuration: configuration,
            dependencies: dependencies
        )
        await relaunched.readyForCapture()
        let lastChance = await relaunched.flush()
        XCTAssertFalse(lastChance)
        XCTAssertEqual(transport.eventRequests.count, 6)
        let queuedNow5 = try await queuedEvents(of: relaunched)
        XCTAssertEqual(queuedNow5, [String]())
    }

    /// The 24 hour TTL outranks the ladder: an unsent event still expires.
    func testTheAgeCapDropsAnEventThatStillHasLadderRungsLeft() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_694_000))
        let transport = TestTransport()
        transport.online = false
        let client = FounderHQEvents(
            apiKey: "fhq_pk_ladder_ttl",
            configuration: .init(
                flushAt: 100,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                eventTTL: 60
            ),
            dependencies: .init(
                clock: clock,
                uuid: TestUUIDProvider(
                    uuids: (1...8).map { "10000000-0000-4000-8000-\(String(format: "%012d", $0))" },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000001"]
                ),
                storage: TestStorage(),
                transport: transport,
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.captureAndWait("stale.me")

        let first = await client.flushOnSchedule()
        XCTAssertFalse(first)
        XCTAssertEqual(transport.eventRequests.count, 1)

        clock.value.addTimeInterval(61)
        let expired = await client.flushOnSchedule()
        XCTAssertTrue(expired)
        XCTAssertEqual(transport.eventRequests.count, 1)
        let queuedNow6 = try await queuedEvents(of: client)
        XCTAssertEqual(queuedNow6, [String]())
    }

    func testPublicCaptureAndAccountCallsPreserveInvocationOrder() async throws {
        let uuids = TestUUIDProvider(
            uuids: (1...20).map {
                "10000000-0000-4000-8000-\(String(format: "%012d", $0))"
            },
            sessionIds: ["01989f2e-7800-7000-8000-000000000099"]
        )
        let client = FounderHQEvents(
            apiKey: "fhq_pk_ordering",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false
            ),
            dependencies: .init(
                clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
                uuid: uuids,
                storage: TestStorage(),
                transport: TestTransport(),
                platformFacts: TestFacts(values: [:])
            )
        )

        client.setAccount("acme")
        client.capture("after.account")
        client.capture("before.switch")
        client.setAccount("new-account")
        await client.readyForCapture()

        let persistedData = await client.persistedStateData()
        let data = try XCTUnwrap(persistedData)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let queue = try XCTUnwrap(persisted["queue"] as? [[String: Any]])
        XCTAssertEqual(queue.compactMap { $0["event"] as? String }, [
            "$groupidentify",
            "after.account",
            "before.switch",
            "$groupidentify",
        ])
        func account(_ index: Int) -> String? {
            let properties = queue[index]["properties"] as? [String: Any]
            let groups = properties?["$groups"] as? [String: Any]
            return groups?["account"] as? String
        }
        XCTAssertEqual(account(1), "acme")
        XCTAssertEqual(account(2), "acme")
        XCTAssertEqual(account(3), "new-account")
    }

    func testPurchasePreparationTimeoutNeverBlocksCheckoutAndMarksContextUnacknowledged() async throws {
        let storage = TestStorage()
        let client = FounderHQEvents(
            apiKey: "fhq_pk_purchase_timeout",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                purchasePrepareTimeout: 0.01
            ),
            dependencies: .init(
                clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
                uuid: TestUUIDProvider(
                    uuids: [
                        "00000000-0000-4000-8000-000000000001",
                        "00000000-0000-4000-8000-000000000002",
                        "00000000-0000-4000-8000-000000000003",
                    ],
                    sessionIds: ["01989f2e-7800-7000-8000-000000000080"]
                ),
                storage: storage,
                transport: NeverReturningTransport(),
                platformFacts: TestFacts(values: [:])
            )
        )

        let started = Date()
        let prepared = try await client.preparePurchase(source: .revenueCat)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(prepared.appAccountToken)

        let persistedStateData = await client.persistedStateData()
        let data = try XCTUnwrap(persistedStateData)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let queue = try XCTUnwrap(persisted["queue"] as? [[String: Any]])
        let event = try XCTUnwrap(queue.first {
            $0["event"] as? String == "$mobile_purchase_prepared"
        })
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(properties["prepared_acknowledgement"] as? String, "UNACKNOWLEDGED")
    }

    func testPurchasePreparationTimeoutIncludesNeverReturningStorage() async throws {
        let storage = NeverReturningStorage()
        let transport = TestTransport()
        transport.online = false
        let client = FounderHQEvents(
            apiKey: "fhq_pk_purchase_storage_timeout",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                purchasePrepareTimeout: 0.01
            ),
            dependencies: .init(
                clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
                uuid: TestUUIDProvider(
                    uuids: [
                        "00000000-0000-4000-8000-000000000001",
                        "00000000-0000-4000-8000-000000000002",
                        "00000000-0000-4000-8000-000000000003",
                    ],
                    sessionIds: ["01989f2e-7800-7000-8000-000000000080"]
                ),
                storage: storage,
                transport: transport,
                platformFacts: TestFacts(values: [:])
            )
        )
        await client.readyForCapture()
        storage.blockWrites()

        let started = Date()
        let prepared = try await client.preparePurchase(source: .revenueCat)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(prepared.appAccountToken)

        let persistedStateData = await client.persistedStateData()
        let data = try XCTUnwrap(persistedStateData)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let queue = try XCTUnwrap(persisted["queue"] as? [[String: Any]])
        let event = try XCTUnwrap(queue.first {
            $0["event"] as? String == "$mobile_purchase_prepared"
        })
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(properties["prepared_acknowledgement"] as? String, "UNACKNOWLEDGED")
    }

    func testRevenueCatPurchaseAndTransferWrappersEmitTypedClaims() async throws {
        let transport = TestTransport()
        let client = FounderHQEvents(
            apiKey: "fhq_pk_revenuecat_claim",
            configuration: .init(
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false
            ),
            dependencies: .init(
                clock: TestClock(Date(timeIntervalSince1970: 1_786_694_000)),
                uuid: TestUUIDProvider(
                    uuids: (1...8).map {
                        "00000000-0000-4000-8000-\(String(format: "%012d", $0))"
                    },
                    sessionIds: ["01989f2e-7800-7000-8000-000000000081"]
                ),
                storage: TestStorage(),
                transport: transport,
                platformFacts: TestFacts(values: [:])
            )
        )
        let transaction = FakeRevenueCatTransaction(
            transactionIdentifier: "rc-transaction",
            originalTransactionIdentifier: "rc-subscription",
            purchaseToken: nil,
            productIdentifier: "family.monthly",
            purchaseDate: Date(timeIntervalSince1970: 1_786_693_900)
        )
        let result = try await client.purchaseWithRevenueCat {
            FakeRevenueCatResult(transaction: transaction)
        }
        XCTAssertEqual(result.transaction.transactionIdentifier, "rc-transaction")
        let receipt = try await client.claimRevenueCatSubscription(
            transaction,
            confirmation: .moveFutureRevenue
        )
        XCTAssertEqual(receipt.status, "queued")
        let flushed = await client.flush()
        XCTAssertTrue(flushed)

        let events = try transport.eventRequests.flatMap { request -> [[String: Any]] in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: Any]
            )
            return try XCTUnwrap(body["batch"] as? [[String: Any]])
        }
        let claims = events.filter { $0["event"] as? String == "$mobile_purchase_claim" }
        XCTAssertEqual(claims.count, 2)
        let properties = try claims.map {
            try XCTUnwrap($0["properties"] as? [String: Any])
        }
        XCTAssertEqual(properties.map { $0["intent"] as? String }, ["PURCHASE", "TRANSFER"])
        XCTAssertTrue(properties.allSatisfy {
            $0["provider_subscription_id"] as? String == "rc-subscription"
        })
    }

    func testExecutesEveryApplicableFixtureExactlyAgainstTheSharedGolden() async throws {
        let suite = try loadSuite()
        let capabilities = Set(try XCTUnwrap(suite.capabilityMatrix["ios"]))
        var ran: [String] = []
        var notApplicable: [String: [String]] = [:]

        for fixture in suite.fixtures {
            let missing = Set(fixture.requires).subtracting(capabilities).sorted()
            guard missing.isEmpty else {
                let reasons = try missing.map { capability in
                    try XCTUnwrap(
                        suite.capabilityExceptions["ios"]?[capability],
                        "\(fixture.name) has no iOS N/A reason for \(capability)"
                    )
                }
                XCTAssertTrue(reasons.allSatisfy { !$0.isEmpty }, fixture.name)
                notApplicable[fixture.name] = reasons
                continue
            }
            let actual = try await runFixture(fixture)
            let expectedTargets = try XCTUnwrap(fixture.expected as? [String: Any])
            let expectedMobile = try XCTUnwrap(expectedTargets["mobile"] as? [String: Any])
            let expected = expandTokens(expectedMobile, tokens: fixture.tokens(
                lib: FounderHQEvents.sdkName,
                libVersion: FounderHQEvents.sdkVersion,
                platform: "ios"
            ))
            let actualJSON = try canonicalJSON(actual)
            let expectedJSON = try canonicalJSON(expected)
            if actualJSON != expectedJSON {
                print("ACTUAL \(fixture.name): \(String(decoding: actualJSON, as: UTF8.self))")
                print("EXPECTED \(fixture.name): \(String(decoding: expectedJSON, as: UTF8.self))")
            }
            XCTAssertEqual(actualJSON, expectedJSON, fixture.name)
            ran.append(fixture.name)
        }

        let expectedRan = suite.fixtures
            .filter { Set($0.requires).isSubset(of: capabilities) }
            .map(\.name)
        XCTAssertEqual(ran, expectedRan)
        XCTAssertEqual(ran.count + notApplicable.count, suite.fixtures.count)
    }

    private func runFixture(_ fixture: Fixture) async throws -> [String: Any] {
        let start = try XCTUnwrap(ISO8601DateFormatter.fhqTest.date(
            from: try XCTUnwrap(fixture.providers["start_time"] as? String)
        ))
        let clock = TestClock(start)
        let uuidSequences = try XCTUnwrap(fixture.providers["uuid_sequences"] as? [String: Any])
        let uuidValues = try XCTUnwrap(uuidSequences["mobile"] as? [String])
        let sessionSequence = fixture.providers["session_uuid_sequences"] as? [String: Any]
        let sessionIds: [String]
        if let mobileSessions = sessionSequence?["mobile"] as? [String] {
            sessionIds = mobileSessions
        } else {
            sessionIds = try XCTUnwrap(fixture.providers["session_uuids"] as? [String])
        }
        let uuids = TestUUIDProvider(uuids: uuidValues, sessionIds: sessionIds)
        let storage = TestStorage()
        try seedInitialStorage(fixture, storage: storage)
        let transport = TestTransport()
        let facts = fixture.platformFacts(for: "ios")
        let dependencies = FounderHQEventsDependencies(
            clock: clock,
            uuid: uuids,
            storage: storage,
            transport: transport,
            platformFacts: TestFacts(values: testJSON(facts))
        )
        var client: FounderHQEvents?
        var apiKey = "fhq_pk_fixture"
        var configuration = FounderHQEventsConfiguration(
            flushAt: 20,
            flushInterval: 0,
            captureLifecycle: false,
            captureScreens: false,
            captureSessions: false,
            captureInstallUpdates: false
        )
        var actionResults: [[String: Any]] = []
        var preparedPurchases: [String: FounderHQPreparedPurchase] = [:]

        for (index, action) in fixture.actions.enumerated() {
            let type = try XCTUnwrap(action["type"] as? String)
            var actionResult: [String: Any] = ["index": index, "type": type]
            switch type {
            case "init":
                apiKey = (try XCTUnwrap(action["api_key"] as? String))
                    .replacingOccurrences(of: "{{platform_api_key}}", with: "fhq_pk_fixture")
                let options = action["options"] as? [String: Any]
                configuration = fixtureConfiguration(options)
                transport.hangWhenOffline = options?["hung_transport"] as? Bool ?? false
                client = FounderHQEvents(
                    apiKey: apiKey,
                    configuration: configuration,
                    dependencies: dependencies
                )
                await client?.readyForCapture()
            case "capture":
                await client?.captureAndWait(
                    try XCTUnwrap(action["event"] as? String),
                    properties: expandActionProperties(action["properties"] as? [String: Any])
                )
            case "identify":
                await client?.identifyAndWait(
                    try XCTUnwrap(action["distinct_id"] as? String),
                    properties: action["properties"] as? [String: Any] ?? [:],
                    account: fixtureAccount(action["account"])
                )
            case "setAccount":
                if let account = fixtureAccount(action["account"]) {
                    await client?.setAccountAndWait(account)
                } else {
                    await client?.clearAccountAndWait()
                }
            case "clearAccount":
                await client?.clearAccountAndWait()
            case "setAccountProperties":
                await client?.setAccountPropertiesAndWait(
                    action["properties"] as? [String: Any] ?? [:]
                )
            case "screen":
                await client?.screenAndWait(
                    try XCTUnwrap(action["name"] as? String),
                    properties: action["properties"] as? [String: Any] ?? [:]
                )
            case "setPersonProperties":
                await client?.setPersonPropertiesAndWait(
                    action["set"] as? [String: Any] ?? [:],
                    setOnce: action["set_once"] as? [String: Any] ?? [:]
                )
            case "register":
                await client?.registerAndWait(action["properties"] as? [String: Any] ?? [:])
            case "registerOnce":
                await client?.registerOnceAndWait(action["properties"] as? [String: Any] ?? [:])
            case "unregister":
                await client?.unregisterAndWait(try XCTUnwrap(action["key"] as? String))
            case "advanceClock":
                clock.value.addTimeInterval(try number(action["milliseconds"]) / 1_000)
            case "goOffline":
                transport.online = false
            case "goOnline":
                transport.online = true
            case "receiveAck":
                transport.nextAck = try XCTUnwrap(action["response"] as? [String: Any])
            case "flush":
                actionResult["result"] = await client?.flush() ?? false
            case "restartWithPersistence":
                client = FounderHQEvents(
                    apiKey: apiKey,
                    configuration: configuration,
                    dependencies: dependencies
                )
                await client?.readyForCapture()
            case "applyRemoteConfig":
                let config = try XCTUnwrap(action["config"] as? [String: Any])
                transport.nextRemoteConfig = config
                let before = transport.configRequests.count
                let refreshed = await client?.refreshRemoteConfig() ?? false
                XCTAssertTrue(refreshed, fixture.name)
                XCTAssertEqual(transport.configRequests.count, before + 1, fixture.name)
                actionResult["config"] = config
                actionResult["transport"] = [
                    "method": "GET",
                    "path": "/i/v1/analytics/config",
                ]
            case "reset":
                await client?.resetAndWait()
            case "optIn":
                await client?.optInAndWait()
            case "optOut":
                await client?.optOutAndWait()
            case "lifecycle":
                await client?.recordLifecycleAndWait(try XCTUnwrap(action["state"] as? String))
            case "prepare-purchase":
                let reference = try XCTUnwrap(action["ref"] as? String)
                let prepared = try await XCTUnwrap(client).preparePurchase(
                    source: try fixturePurchaseSource(action["source"])
                )
                preparedPurchases[reference] = prepared
                actionResult["result"] = [
                    "purchaseContextToken": prepared.purchaseContextToken.uuidString.lowercased(),
                    "appAccountToken": prepared.appAccountToken?.uuidString.lowercased()
                        as Any? ?? NSNull(),
                    "obfuscatedExternalAccountId": prepared.obfuscatedExternalAccountId
                        as Any? ?? NSNull(),
                ] as [String: Any]
                transport.releaseOfflineHang()
            case "observe-purchase":
                let reference = try XCTUnwrap(action["prepared"] as? String)
                let prepared = try XCTUnwrap(
                    preparedPurchases[reference],
                    "\(fixture.name) references unknown preparation \(reference)"
                )
                try await XCTUnwrap(client).observePurchase(
                    try fixtureObservedPurchase(action["purchase"]),
                    prepared: prepared
                )
            case "claim-subscription":
                let receipt = try await XCTUnwrap(client).claimSubscription(
                    try fixtureObservedPurchase(action["purchase"]),
                    confirmation: .moveFutureRevenue
                )
                actionResult["result"] = [
                    "claimId": receipt.claimId,
                    "status": receipt.status,
                ]
            default:
                XCTFail("Unexpected iOS fixture action \(type) in \(fixture.name)")
            }
            actionResults.append(actionResult)
        }

        XCTAssertEqual(uuids.remainingUUIDs, 0, "\(fixture.name) left UUID provider values")
        XCTAssertEqual(uuids.remainingSessionIds, 0, "\(fixture.name) left session UUIDs")
        for request in transport.eventRequests {
            XCTAssertEqual(request.url?.path, "/i/v2/e", fixture.name)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "FounderHq-Sdk-Info"),
                "\(FounderHQEvents.sdkName)/\(FounderHQEvents.sdkVersion)",
                fixture.name
            )
        }
        for request in transport.configRequests {
            XCTAssertEqual(request.url?.path, "/i/v1/analytics/config", fixture.name)
            XCTAssertEqual(request.httpMethod, "GET", fixture.name)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        }
        let wire = try transport.eventRequests.map { request -> Any in
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
        }
        let maybePersistedData = await client?.persistedStateData()
        let persistedData = try XCTUnwrap(maybePersistedData)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        var normalized = normalizePersistedState(persisted)
        normalized["remote_config"] = storage.string(
            forKey: "com.founderhq.events.config.v1.fhq_pk_fixture"
        ).flatMap { raw in
            raw.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            }
        } ?? NSNull()
        return [
            "wire_batches": wire,
            "persisted_state": normalized,
            "directive_handling": ["actions": actionResults],
        ]
    }
}

private struct FixtureSuite {
    let capabilityMatrix: [String: [String]]
    let capabilityExceptions: [String: [String: String]]
    let fixtures: [Fixture]
}

private struct Fixture {
    let name: String
    let requires: [String]
    let providers: [String: Any]
    let actions: [[String: Any]]
    let expected: Any

    func platformFacts(for platform: String) -> [String: Any] {
        let all = providers["platform_facts"] as? [String: Any]
        return all?[platform] as? [String: Any] ?? [:]
    }

    func tokens(lib: String, libVersion: String, platform: String) -> [String: Any] {
        var output: [String: Any] = [
            "oversize_65537_bytes": String(repeating: "x", count: 65_537),
            "lib": lib,
            "lib_version": libVersion,
            "platform": platform,
        ]
        for (key, value) in platformFacts(for: platform) {
            output[String(key.drop(while: { $0 == "$" }))] = value
        }
        return output
    }
}

private func loadSuite() throws -> FixtureSuite {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let standaloneFixture = packageRoot.appendingPathComponent("fixtures/conformance-v2.json")
    let url = FileManager.default.fileExists(atPath: standaloneFixture.path)
        ? standaloneFixture
        : packageRoot.deletingLastPathComponent()
            .appendingPathComponent("events-core/fixtures/conformance-v2.json")
    let suite = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    let matrixAny = try XCTUnwrap(suite["capability_matrix"] as? [String: Any])
    let matrix = try Dictionary(uniqueKeysWithValues: matrixAny.map { key, value in
        (key, try XCTUnwrap(value as? [String]))
    })
    let exceptionsAny = try XCTUnwrap(suite["capability_exceptions"] as? [String: Any])
    let exceptions = try Dictionary(uniqueKeysWithValues: exceptionsAny.map { key, value in
        (key, try XCTUnwrap(value as? [String: String]))
    })
    let rawFixtures = try XCTUnwrap(suite["fixtures"] as? [[String: Any]])
    let fixtures = try rawFixtures.map { raw in
        Fixture(
            name: try XCTUnwrap(raw["name"] as? String),
            requires: try XCTUnwrap(raw["requires"] as? [String]),
            providers: try XCTUnwrap(raw["providers"] as? [String: Any]),
            actions: try XCTUnwrap(raw["actions"] as? [[String: Any]]),
            expected: try XCTUnwrap(raw["expected"])
        )
    }
    return FixtureSuite(
        capabilityMatrix: matrix,
        capabilityExceptions: exceptions,
        fixtures: fixtures
    )
}

private func fixtureConfiguration(_ options: [String: Any]?) -> FounderHQEventsConfiguration {
    FounderHQEventsConfiguration(
        flushAt: 20,
        flushInterval: 0,
        personProfiles: profile(options?["person_profiles"] as? String),
        optOutByDefault: options?["opt_out_by_default"] as? Bool ?? false,
        captureLifecycle: options?["capture_lifecycle"] as? Bool ?? false,
        captureScreens: options?["capture_screens"] as? Bool ?? false,
        captureSessions: options?["capture_sessions"] as? Bool ?? false,
        captureInstallUpdates: false,
        remoteConfig: options?["remote_config"] as? Bool ?? true,
        account: fixtureAccount(options?["account"]),
        purchasePrepareTimeout:
            (options?["purchase_prepare_timeout_ms"] as? NSNumber)
                .map { $0.doubleValue / 1_000 } ?? 3
    )
}

private func fixturePurchaseSource(_ value: Any?) throws -> FounderHQPurchaseSource {
    switch try XCTUnwrap(value as? String) {
    case "revenuecat": return .revenueCat
    case "app_store": return .storeKit
    case "google_play": return .playBilling
    default: throw NSError(domain: "FounderHQFixture", code: 1)
    }
}

private func fixtureObservedPurchase(_ value: Any?) throws -> FounderHQObservedPurchase {
    let purchase = try XCTUnwrap(value as? [String: Any])
    let source = try fixturePurchaseSource(purchase["source"])
    switch source {
    case .revenueCat:
        let transactionId = try XCTUnwrap(purchase["transactionIdentifier"] as? String)
        return .init(
            source: source,
            store: (purchase["store"] as? String ?? "app_store").uppercased(),
            transactionId: transactionId,
            subscriptionId:
                purchase["originalTransactionIdentifier"] as? String ?? transactionId,
            purchaseToken: purchase["purchaseToken"] as? String,
            productId: purchase["productIdentifier"] as? String,
            purchasedAt: purchase["purchaseDate"] as? String
        )
    case .storeKit:
        return .init(
            source: source,
            store: "APP_STORE",
            transactionId: purchase["transactionId"] as? String,
            subscriptionId: purchase["originalTransactionId"] as? String,
            productId: purchase["productId"] as? String,
            purchasedAt: purchase["purchaseDate"] as? String
        )
    case .playBilling:
        let purchaseToken = try XCTUnwrap(purchase["purchaseToken"] as? String)
        let purchasedAt = (purchase["purchaseTime"] as? NSNumber).map {
            ISO8601DateFormatter.fhqTest.string(
                from: Date(timeIntervalSince1970: $0.doubleValue / 1_000)
            )
        }
        return .init(
            source: source,
            store: "GOOGLE_PLAY",
            transactionId: purchase["orderId"] as? String,
            subscriptionId: purchaseToken,
            purchaseToken: purchaseToken,
            productId: (purchase["products"] as? [String])?.first,
            purchasedAt: purchasedAt
        )
    }
}

private func fixtureAccount(_ value: Any?) -> FounderHQAccountContext? {
    if let key = value as? String {
        return FounderHQAccountContext(key: key)
    }
    guard let account = value as? [String: Any],
          let key = account["key"] as? String
    else { return nil }
    return FounderHQAccountContext(
        key: key,
        properties: account["properties"] as? [String: Any] ?? [:],
        contextToken: account["contextToken"] as? String
    )
}

private func profile(_ value: String?) -> FounderHQPersonProfiles {
    switch value {
    case "always": return .always
    case "never": return .never
    default: return .identifiedOnly
    }
}

private func seedInitialStorage(_ fixture: Fixture, storage: TestStorage) throws {
    guard let initial = fixture.providers["initial_storage"] as? [String: Any] else { return }
    if let remoteConfig = initial["remote_config"] as? [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: remoteConfig, options: [.sortedKeys])
        storage.set(
            String(decoding: data, as: UTF8.self),
            forKey: "com.founderhq.events.config.v1.fhq_pk_fixture"
        )
    }
    guard var state = initial["state"] as? [String: Any] else { return }
    for key in ["sessionStartedAt", "lastActivityAt"] {
        if let milliseconds = state[key] as? NSNumber {
            state[key] = milliseconds.doubleValue / 1_000 - 978_307_200
        }
    }
    let data = try JSONSerialization.data(withJSONObject: state)
    storage.set(data, forKey: "com.founderhq.events.v2.fhq_pk_fixture")
}

private func queuedEvents(of client: FounderHQEvents) async throws -> [String] {
    let persisted = await client.persistedStateData()
    let state = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try XCTUnwrap(persisted)) as? [String: Any]
    )
    let queue = try XCTUnwrap(state["queue"] as? [[String: Any]])
    return queue.compactMap { $0["event"] as? String }
}

private func normalizePersistedState(_ state: [String: Any]) -> [String: Any] {
    [
        "anonymous_id": state["anonymousId"] as Any,
        "distinct_id": state["distinctId"] as Any,
        "identified": state["identified"] as Any,
        "session_id": state["sessionId"] as Any,
        "session_started_at": epochMilliseconds(state["sessionStartedAt"]),
        "last_activity_at": epochMilliseconds(state["lastActivityAt"]),
        "registered": state["registered"] as Any,
        "pending_set": state["pendingSet"] as Any,
        "pending_set_once": state["pendingSetOnce"] as Any,
        "opted_out": state["optedOut"] as Any,
        "app_version": NSNull(),
        "queue": state["queue"] as Any,
    ]
}

private func epochMilliseconds(_ value: Any?) -> Int {
    let seconds = (value as? NSNumber)?.doubleValue ?? 0
    return Int(round((seconds + 978_307_200) * 1_000))
}

private func expandActionProperties(_ value: [String: Any]?) -> [String: Any] {
    expandTokens(value ?? [:], tokens: [
        "oversize_65537_bytes": String(repeating: "x", count: 65_537),
    ]) as? [String: Any] ?? [:]
}

private func expandTokens(_ value: Any, tokens: [String: Any]) -> Any {
    if let string = value as? String,
       string.hasPrefix("{{"), string.hasSuffix("}}"),
       let replacement = tokens[String(string.dropFirst(2).dropLast(2))] {
        return replacement
    }
    if let values = value as? [Any] {
        return values.map { expandTokens($0, tokens: tokens) }
    }
    if let values = value as? [String: Any] {
        return values.mapValues { expandTokens($0, tokens: tokens) }
    }
    return value
}

private func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func number(_ value: Any?) throws -> Double {
    try XCTUnwrap(value as? NSNumber).doubleValue
}

private func testJSON(_ input: [String: Any]) -> JSONObject {
    input.mapValues(testJSONValue)
}

private func testJSONValue(_ value: Any) -> JSONValue {
    switch value {
    case let item as String: return .string(item)
    case let item as NSNumber:
        return CFGetTypeID(item) == CFBooleanGetTypeID()
            ? .bool(item.boolValue)
            : .number(item.doubleValue)
    case let item as [String: Any]: return .object(testJSON(item))
    case let item as [Any]: return .array(item.map(testJSONValue))
    default: return .null
    }
}

private func isTestUUIDv7(_ value: String) -> Bool {
    value.range(
        of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: .regularExpression
    ) != nil
}

private final class TestClock: FounderHQClock, @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

private final class TestUUIDProvider: FounderHQUUIDProvider, @unchecked Sendable {
    private var uuids: [String]
    private var sessionIds: [String]
    init(uuids: [String], sessionIds: [String]) {
        self.uuids = uuids
        self.sessionIds = sessionIds
    }
    var remainingUUIDs: Int { uuids.count }
    var remainingSessionIds: Int { sessionIds.count }
    func uuid() -> String {
        precondition(!uuids.isEmpty, "Fixture exhausted its UUID provider")
        return uuids.removeFirst()
    }
    func uuidV7(at _: Date) -> String {
        precondition(!sessionIds.isEmpty, "Fixture exhausted its session UUID provider")
        return sessionIds.removeFirst()
    }
}

private final class TestStorage: FounderHQStorage, @unchecked Sendable {
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    func data(forKey key: String) -> Data? { dataValues[key] }
    func string(forKey key: String) -> String? { stringValues[key] }
    func set(_ data: Data?, forKey key: String) { dataValues[key] = data }
    func set(_ value: String?, forKey key: String) { stringValues[key] = value }
}

private final class NeverReturningStorage: FounderHQStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let blockedWrite = DispatchSemaphore(value: 0)
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    private var writesBlocked = false

    func blockWrites() {
        lock.lock()
        writesBlocked = true
        lock.unlock()
    }

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return dataValues[key]
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stringValues[key]
    }

    func set(_ data: Data?, forKey key: String) {
        waitIfBlocked()
        lock.lock()
        dataValues[key] = data
        lock.unlock()
    }

    func set(_ value: String?, forKey key: String) {
        waitIfBlocked()
        lock.lock()
        stringValues[key] = value
        lock.unlock()
    }

    private func waitIfBlocked() {
        lock.lock()
        let shouldBlock = writesBlocked
        lock.unlock()
        if shouldBlock { blockedWrite.wait() }
    }
}

private final class TestTransport: FounderHQTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var eventRequests: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    var configRequests: [URLRequest] { requests.filter { $0.httpMethod == "GET" } }
    var online = true
    var hangWhenOffline = false
    private var offlineHangReleased = false
    var nextAck: [String: Any]?
    var nextRemoteConfig: [String: Any]?

    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse {
        requests.append(request)
        while !online && hangWhenOffline && !offlineHangReleased {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard online else { throw URLError(.notConnectedToInternet) }
        if request.httpMethod == "GET" {
            let config = nextRemoteConfig ?? [:]
            nextRemoteConfig = nil
            return .init(
                data: try JSONSerialization.data(withJSONObject: ["config": config]),
                statusCode: 200
            )
        }
        if nextAck?["kind"] as? String == "retry" {
            nextAck = nil
            throw URLError(.timedOut)
        }
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        let requested = nextAck
        nextAck = nil
        let requestedResults = requested?["results"] as? [String: [String: Any]] ?? [:]
        let results = Dictionary(uniqueKeysWithValues: batch.map { event -> (String, [String: Any]) in
            let uuid = event["uuid"] as? String ?? ""
            let fixtureResult = requestedResults[uuid] ?? [:]
            var result: [String: Any] = [
                "result": fixtureResult["result"] as? String ?? "ok",
            ]
            if let details = fixtureResult["details"] { result["details"] = details }
            return (uuid, result)
        })
        var response: [String: Any] = ["results": results]
        if let directives = requested?["directives"] { response["directives"] = directives }
        return .init(
            data: try JSONSerialization.data(withJSONObject: response),
            statusCode: 202
        )
    }

    func releaseOfflineHang() { offlineHangReleased = true }
}

private final class NeverReturningTransport: FounderHQTransport, @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse {
        _ = request
        for await _ in stream {}
        throw CancellationError()
    }
}

private struct FakeRevenueCatResult: Sendable {
    let transaction: FakeRevenueCatTransaction
}

private struct FakeRevenueCatTransaction: Sendable {
    let transactionIdentifier: String
    let originalTransactionIdentifier: String
    let purchaseToken: String?
    let productIdentifier: String
    let purchaseDate: Date
}

private actor TestRevenueCatIdentity: FounderHQRevenueCatIdentity {
    private var configured: [String] = []
    private var loggedIn: [String] = []

    func configure(appUserID: String) async { configured.append(appUserID) }
    func logIn(appUserID: String) async { loggedIn.append(appUserID) }
    func snapshot() -> (configured: [String], loggedIn: [String]) {
        (configured, loggedIn)
    }
}

private struct TestFacts: FounderHQPlatformFactsProvider {
    let values: JSONObject
    func properties() -> JSONObject { values }
}

private final class TestScreenCaptureInstaller: FounderHQScreenCaptureInstalling, @unchecked Sendable {
    private(set) var installCount = 0
    func install(client _: FounderHQEvents) { installCount += 1 }
}

private extension ISO8601DateFormatter {
    static let fhqTest: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
