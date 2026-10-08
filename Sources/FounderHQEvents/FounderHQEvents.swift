import Foundation
import CoreFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum FounderHQPersonProfiles: String, Codable, Sendable {
    case always
    case identifiedOnly = "identified_only"
    case never
}

public protocol FounderHQClock: Sendable {
    func now() -> Date
}

public protocol FounderHQUUIDProvider: Sendable {
    func uuid() -> String
    func uuidV7(at date: Date) -> String
}

public protocol FounderHQStorage: Sendable {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ data: Data?, forKey key: String)
    func set(_ value: String?, forKey key: String)
}

public struct FounderHQTransportResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol FounderHQTransport: Sendable {
    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse
}

public protocol FounderHQPlatformFactsProvider: Sendable {
    /** Canonical v2 `$` properties. Dimensions must already be physical pixels. */
    func properties() -> JSONObject
}

public protocol FounderHQScreenCaptureInstalling: Sendable {
    func install(client: FounderHQEvents)
}

public protocol FounderHQRevenueCatIdentity: Sendable {
    func configure(appUserID: String) async
    func logIn(appUserID: String) async
}

public struct FounderHQPurchaseAttribution: Sendable, Equatable {
    public let appAccountToken: UUID
    public let obfuscatedExternalAccountId: String
    public let revenueCatAppUserID: String
}

public enum FounderHQPurchaseSource: Sendable, Equatable {
    case revenueCat
    case storeKit
    case playBilling
}

public struct FounderHQPreparedPurchase: Sendable {
    public let purchaseContextToken: UUID
    public let appAccountToken: UUID?
    public let obfuscatedExternalAccountId: String?
    let source: FounderHQPurchaseSource
    let accountProperties: JSONObject
}

public struct FounderHQObservedPurchase: Sendable {
    public let source: FounderHQPurchaseSource
    public let store: String
    public let transactionId: String?
    public let subscriptionId: String?
    public let purchaseToken: String?
    public let productId: String?
    public let purchasedAt: String?

    public init(
        source: FounderHQPurchaseSource,
        store: String,
        transactionId: String? = nil,
        subscriptionId: String? = nil,
        purchaseToken: String? = nil,
        productId: String? = nil,
        purchasedAt: String? = nil
    ) {
        self.source = source
        self.store = store
        self.transactionId = transactionId
        self.subscriptionId = subscriptionId
        self.purchaseToken = purchaseToken
        self.productId = productId
        self.purchasedAt = purchasedAt
    }
}

public enum FounderHQRevenueClaimConfirmation: Sendable, Equatable {
    case moveFutureRevenue
}

public struct FounderHQSubscriptionClaimReceipt: Sendable, Equatable {
    public let claimId: String
    public let status: String
}

public struct FounderHQAccountContext: Sendable {
    public let key: String
    public let properties: JSONObject
    public let contextToken: String?

    public init(
        key: String,
        properties: [String: Any] = [:],
        contextToken: String? = nil
    ) {
        self.key = key
        self.properties = json(properties)
        self.contextToken = contextToken
    }
}

public struct FounderHQEventsDependencies: Sendable {
    public var clock: any FounderHQClock
    public var uuid: any FounderHQUUIDProvider
    public var storage: any FounderHQStorage
    public var transport: any FounderHQTransport
    public var platformFacts: any FounderHQPlatformFactsProvider
    public var screenCapture: any FounderHQScreenCaptureInstalling
    public var colorScheme: @MainActor @Sendable () -> String?

    public init(
        clock: any FounderHQClock = FounderHQSystemClock(),
        uuid: any FounderHQUUIDProvider = FounderHQSystemUUIDProvider(),
        storage: any FounderHQStorage = FounderHQUserDefaultsStorage(),
        transport: any FounderHQTransport = FounderHQURLSessionTransport(),
        platformFacts: any FounderHQPlatformFactsProvider = FounderHQSystemPlatformFactsProvider(),
        screenCapture: any FounderHQScreenCaptureInstalling = FounderHQDefaultScreenCaptureInstaller(),
        colorScheme: @escaping @MainActor @Sendable () -> String? = { founderHQSystemColorScheme() }
    ) {
        self.clock = clock
        self.uuid = uuid
        self.storage = storage
        self.transport = transport
        self.platformFacts = platformFacts
        self.screenCapture = screenCapture
        self.colorScheme = colorScheme
    }
}

public struct FounderHQEventsConfiguration: Sendable {
    public var host: URL
    public var flushAt: Int
    public var flushInterval: TimeInterval
    public var personProfiles: FounderHQPersonProfiles
    public var optOutByDefault: Bool
    public var captureLifecycle: Bool
    public var captureScreens: Bool
    public var captureSessions: Bool
    public var captureInstallUpdates: Bool
    public var remoteConfig: Bool
    public var account: FounderHQAccountContext?
    public var purchasePrepareTimeout: TimeInterval
    public var maxQueueSize: Int
    public var eventTTL: TimeInterval
    /**
     How many delivery attempts a queued event gets after its first one fails,
     and so how far it climbs the retry ladder.

     The ladder is: send at once, then wait 30 seconds, 30 seconds, 2 minutes,
     5 minutes, and finally try once more the next time the SDK starts in a
     new process. The first two rungs recover the common failure, which is a
     phone in a lift, in a tunnel, or on a train. The longer rungs cost the
     customer almost nothing, because an offline app has nothing else to do.
     The last rung waits for a launch instead of a clock, so an event whose
     app was killed during an outage still gets one more chance. An event the
     ingest API will never accept still dies, because the ladder ends.

     `eventTTL` outranks the ladder: an event older than 24 hours is dropped
     even with rungs left, so the queue can never hold stale data.

     The default, 5, is the whole ladder. A smaller number keeps the first
     rungs and drops the rest, so `maxRetries: 2` waits 30 seconds, waits 30
     seconds again, and then gives up. `0` sends once and never retries.

     With `debug` on, the SDK says how many events it dropped and why.
     */
    public var maxRetries: Int
    /**
     Captures `$autocapture` for button and control taps, and `$rageclick`
     when the same control is tapped three times inside one second. Off by
     default: a tap stream is the most surprising thing an analytics SDK can
     turn on for you, so the app has to ask for it.

     The SDK stores the element's type, its accessibility identifier and
     label, the title a button, bar button, or segmented control renders, and
     the view hierarchy path. It never stores what a person typed: text
     fields, text views, and search bars are skipped whole. It never stores
     tap coordinates.

     This flag is the default, not the ceiling. Remote config wins in both
     directions once it arrives: `autocapture` can switch element capture off
     for every install at once, and on for an app that shipped with it
     `false`. `capture_rageclicks` gates rage clicks on top of that.
     */
    public var captureElementInteractions: Bool
    /**
     Exact hostnames — no protocol, path, port, or wildcard — whose requests
     carry the current session id in the `x-founderhq-session-id` header, so
     backend events join the visit that caused them. Only the session id
     travels: a distinct id in a header is forgeable and the ingest API
     ignores it. Requests to any other host are left alone, because a session
     id must never reach a third party.
     */
    public var tracingHeaders: [String]?
    /**
     Emits `$push_notification_opened` when the user taps a notification. On
     by default because the tap is the moment the app comes back, and the SDK
     only reads the action, category, and request identifiers, plus the two
     FounderHQ keys of the payload (`fhqOutboundMessageId` and `fhqLink`) —
     never the title, body, the rest of the payload, or anything the user
     typed in reply.
     */
    public var capturePushNotificationOpened: Bool
    /**
     Called on the main actor when the user opens a notification, with its
     FounderHQ message id and link. Open the link here; the SDK never does.
     It runs for the opens the SDK reports by itself. With
     `capturePushNotificationOpened` off, it runs for the opens your app
     reports with `capturePushNotificationOpened(userInfo:)`.
     */
    public var onPushNotificationOpened: FounderHQPushOpenedHandler?
    /**
     Prints what the SDK drops, refuses, or fails to install. Off by default
     so a shipping app stays quiet; turn it on while you wire the SDK up.
     */
    public var debug: Bool
    /// Enriches screens and taps without changing which events are captured.
    public var autoProperties: FounderHQAutoProperties?
    /// Runs on the state actor before queueing, including identity retries.
    /// Purchase and push device control events bypass this hook. Returning nil or throwing drops other events.
    public var beforeSend: FounderHQBeforeSend?
    public init(
        host: URL = URL(string: "https://i.getfounderhq.com")!,
        flushAt: Int = 20,
        flushInterval: TimeInterval = 10,
        personProfiles: FounderHQPersonProfiles = .identifiedOnly,
        optOutByDefault: Bool = false,
        captureLifecycle: Bool = true,
        captureScreens: Bool = true,
        captureSessions: Bool = true,
        captureInstallUpdates: Bool = true,
        remoteConfig: Bool = true,
        account: FounderHQAccountContext? = nil,
        purchasePrepareTimeout: TimeInterval = 3,
        maxQueueSize: Int = 1_000,
        eventTTL: TimeInterval = 24 * 60 * 60,
        maxRetries: Int = 5,
        captureElementInteractions: Bool = false,
        tracingHeaders: [String]? = nil,
        capturePushNotificationOpened: Bool = true,
        debug: Bool = false,
        autoProperties: FounderHQAutoProperties? = nil,
        beforeSend: FounderHQBeforeSend? = nil,
        onPushNotificationOpened: FounderHQPushOpenedHandler? = nil
    ) {
        self.host = host
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.personProfiles = personProfiles
        self.optOutByDefault = optOutByDefault
        self.captureLifecycle = captureLifecycle
        self.captureScreens = captureScreens
        self.captureSessions = captureSessions
        self.captureInstallUpdates = captureInstallUpdates
        self.remoteConfig = remoteConfig
        self.account = account
        self.purchasePrepareTimeout = purchasePrepareTimeout
        self.maxQueueSize = maxQueueSize
        self.eventTTL = eventTTL
        self.maxRetries = maxRetries
        self.captureElementInteractions = captureElementInteractions
        self.tracingHeaders = tracingHeaders
        self.capturePushNotificationOpened = capturePushNotificationOpened
        self.debug = debug
        self.autoProperties = autoProperties
        self.beforeSend = beforeSend
        self.onPushNotificationOpened = onPushNotificationOpened
    }
}

public final class FounderHQEvents: @unchecked Sendable {
    public static let sdkName = "FounderHQEvents"
    public static let sdkVersion = "1.3.0"

    private let apiKey: String
    private let configuration: FounderHQEventsConfiguration
    private let dependencies: FounderHQEventsDependencies
    private let automaticProperties: FounderHQAutomaticProperties
    private let state: EventsState
    private let stateStorageKey: String
    private let capturePolicy: AutomaticCapturePolicy
    private let remoteConfigKey: String
    private let revenueCatIdentity: (any FounderHQRevenueCatIdentity)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var initialization: Task<Void, Never>?
    private var startPushRegistration: Task<Void, Never>?
    private let invocationLock = NSLock()
    private var invocationTail: Task<Void, Never>?
    private var screenCaptureInstalled = false
    private var elementCaptureInstalled = false
    private var tracingHeadersInstalled = false
    private let sessionSnapshot = FounderHQSessionSnapshot()
    private let interactionSnapshot = FounderHQInteractionCaptureSnapshot()

    public init(
        apiKey: String,
        configuration: FounderHQEventsConfiguration = .init(),
        dependencies: FounderHQEventsDependencies = .init(),
        revenueCatIdentity: (any FounderHQRevenueCatIdentity)? = nil
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.automaticProperties = FounderHQAutomaticProperties(hook: configuration.autoProperties)
        self.dependencies = dependencies
        self.revenueCatIdentity = revenueCatIdentity
        self.remoteConfigKey = "com.founderhq.events.config.v1.\(String(apiKey.prefix(16)))"
        let stateStorageKey = "com.founderhq.events.v2.\(String(apiKey.prefix(16)))"
        let stateWriter = FounderHQStateWriter(
            storage: dependencies.storage,
            key: stateStorageKey
        )
        self.stateStorageKey = stateStorageKey
        self.capturePolicy = AutomaticCapturePolicy(
            lifecycle: configuration.captureLifecycle,
            screens: configuration.captureScreens,
            sessions: configuration.captureSessions,
            elements: configuration.captureElementInteractions
        )
        interactionSnapshot.set(
            elements: configuration.captureElementInteractions,
            rageClicks: configuration.captureElementInteractions
        )
        self.state = EventsState(
            key: stateStorageKey,
            optOutByDefault: configuration.optOutByDefault,
            storage: dependencies.storage,
            writer: stateWriter,
            clock: dependencies.clock,
            uuid: dependencies.uuid,
            maxQueueSize: configuration.maxQueueSize,
            eventTTL: configuration.eventTTL,
            maxRetries: configuration.maxRetries,
            retryLadder: founderHQRetryLadder,
            debug: configuration.debug,
            beforeSend: configuration.beforeSend
        )
        startTimer()
        // Before the start task, not inside it: iOS reports the tap that
        // started the app right after `didFinishLaunching`, and the start
        // task can wait for remote config first.
        installPushCapture()
        let start = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            // Before anything else this start queues: a removal that never
            // reached the server goes out first.
            await requeuePendingPushRemovals()
            if let account = configuration.account {
                await setAccountCore(account, emit: true)
            }
            if let revenueCatIdentity {
                let token = await state.enablePurchaseAttribution()
                await revenueCatIdentity.configure(appUserID: token)
                await captureCore("$set", properties: [
                    "$purchase_attribution_token": .string(token),
                ])
            }
            if configuration.remoteConfig {
                await loadCachedRemoteConfig()
                _ = await fetchRemoteConfig()
            }
            await armAutomaticCapture()
            await refreshSessionSnapshot()
            if state.needsSessionStart,
               await capturePolicy.sessions,
               !(await state.isOptedOut) {
                await captureCore("$session_start", properties: [:])
            }
            if configuration.captureInstallUpdates { await captureInstallOrUpdate() }
            // Decided here, before any call of the app can run.
            return await hasPushDeviceToRegister()
        }
        initialization = Task { _ = await start.value }
        // Every start registers the stored token again for an identified
        // person: it is what keeps "the last used device" true on the server.
        // It reads the notification permission from the system, so it runs
        // after the start task: no other call waits for that read.
        startPushRegistration = Task { [weak self] in
            guard await start.value else { return }
            await self?.registerStoredPushDeviceAtStart()
        }
    }

    public func capture(_ event: String, properties: [String: Any] = [:]) {
        _ = enqueueInvocation { [weak self] in
            await self?.captureOperation(event, properties: properties)
        }
    }

    public func captureAndWait(_ event: String, properties: [String: Any] = [:]) async {
        await enqueueInvocation { [weak self] in
            await self?.captureOperation(event, properties: properties)
        }.value
    }

    private func captureOperation(_ event: String, properties: [String: Any]) async {
        await initialization?.value
        await captureCore(event, properties: json(properties))
    }

    public func readyForCapture() async {
        await initialization?.value
        await startPushRegistration?.value
        await invocationSnapshot()?.value
    }

    public func identify(
        _ distinctId: String,
        properties: [String: Any] = [:],
        account: FounderHQAccountContext? = nil
    ) {
        _ = enqueueInvocation { [weak self] in
            await self?.identifyOperation(distinctId, properties: properties, account: account)
        }
    }

    public func identifyAndWait(
        _ distinctId: String,
        properties: [String: Any] = [:],
        account: FounderHQAccountContext? = nil
    ) async {
        await enqueueInvocation { [weak self] in
            await self?.identifyOperation(distinctId, properties: properties, account: account)
        }.value
    }

    private func identifyOperation(
        _ distinctId: String,
        properties: [String: Any],
        account: FounderHQAccountContext?
    ) async {
        await initialization?.value
        guard normalizeDistinctId(distinctId) != nil else {
            NSLog("[FounderHQEvents] identify ignored an invalid distinct ID")
            return
        }
        let previousDistinctId = await state.distinctId
        let wasIdentified = await state.isIdentified
        let transition = await state.identify(
            distinctId,
            properties: json(properties),
            mode: configuration.personProfiles,
            account: account
        )
        guard let transition else { return }
        if transition.purchaseAttributionEnabled {
            await revenueCatIdentity?.logIn(appUserID: transition.purchaseAttributionToken)
        }
        var identifyProperties: JSONObject = [
            "$anon_distinct_id": .string(transition.anonymousId),
            "$set": .object(transition.set),
            "$set_once": .object(transition.setOnce),
        ]
        if let groupSet = transition.groupSet {
            identifyProperties["$group_set"] = .object(groupSet)
        }
        await captureCore("$identify", properties: identifyProperties)
        // After `$identify`, so the server already knows who this person is. A
        // registration for another person moves the device to them. The same
        // person again changes nothing, so nothing is sent.
        let currentDistinctId = await state.distinctId
        if !wasIdentified || previousDistinctId != currentDistinctId {
            await registerStoredPushDevice()
        }
    }

    public func setAccount(
        _ key: String,
        properties: [String: Any] = [:],
        contextToken: String? = nil
    ) {
        setAccount(.init(key: key, properties: properties, contextToken: contextToken))
    }

    public func setAccount(_ account: FounderHQAccountContext) {
        _ = enqueueInvocation { [weak self] in
            await self?.setAccountOperation(account)
        }
    }

    public func setAccountAndWait(_ account: FounderHQAccountContext) async {
        await enqueueInvocation { [weak self] in
            await self?.setAccountOperation(account)
        }.value
    }

    private func setAccountOperation(_ account: FounderHQAccountContext) async {
        await initialization?.value
        await setAccountCore(account, emit: true)
    }

    public func clearAccount() {
        _ = enqueueInvocation { [weak self] in await self?.clearAccountOperation() }
    }
    public func clearAccountAndWait() async {
        await enqueueInvocation { [weak self] in await self?.clearAccountOperation() }.value
    }
    private func clearAccountOperation() async {
        await initialization?.value
        await state.clearAccount()
    }

    /** Alias for logout flows that use plural account/group terminology. */
    public func resetAccounts() { clearAccount() }
    public func resetAccountsAndWait() async { await clearAccountAndWait() }

    public func setAccountProperties(_ properties: [String: Any]) {
        _ = enqueueInvocation { [weak self] in
            await self?.setAccountPropertiesOperation(properties)
        }
    }

    public func setAccountPropertiesAndWait(_ properties: [String: Any]) async {
        await enqueueInvocation { [weak self] in
            await self?.setAccountPropertiesOperation(properties)
        }.value
    }

    private func setAccountPropertiesOperation(_ properties: [String: Any]) async {
        await initialization?.value
        guard let groupSet = await state.setAccountProperties(json(properties)) else { return }
        await captureCore("$groupidentify", properties: ["$group_set": .object(groupSet)])
    }

    private func setAccountCore(_ account: FounderHQAccountContext, emit: Bool) async {
        guard let groupSet = await state.setAccount(account) else { return }
        if emit {
            await captureCore("$groupidentify", properties: ["$group_set": .object(groupSet)])
        }
    }

    public func setPersonProperties(
        _ set: [String: Any],
        setOnce: [String: Any] = [:]
    ) {
        _ = enqueueInvocation { [weak self] in
            await self?.setPersonPropertiesOperation(set, setOnce: setOnce)
        }
    }

    public func setPersonPropertiesAndWait(
        _ set: [String: Any],
        setOnce: [String: Any] = [:]
    ) async {
        await enqueueInvocation { [weak self] in
            await self?.setPersonPropertiesOperation(set, setOnce: setOnce)
        }.value
    }

    private func setPersonPropertiesOperation(
        _ set: [String: Any],
        setOnce: [String: Any]
    ) async {
        await initialization?.value
        let mutation = await state.personMutation(
            set: standaloneProperties(json(set)),
            setOnce: standaloneProperties(json(setOnce)),
            mode: configuration.personProfiles
        )
        if let mutation {
            await captureCore("$set", properties: [
                "$set": .object(mutation.set),
                "$set_once": .object(mutation.setOnce),
            ])
        }
    }

    public func screen(_ name: String, properties: [String: Any] = [:]) {
        _ = enqueueInvocation { [weak self] in
            await self?.screenOperation(name, properties: properties)
        }
    }

    public func screenAndWait(_ name: String, properties: [String: Any] = [:]) async {
        await enqueueInvocation { [weak self] in
            await self?.screenOperation(name, properties: properties)
        }.value
    }

    private func screenOperation(_ name: String, properties: [String: Any]) async {
        await initialization?.value
        await MainActor.run { automaticProperties.screenName = name }
        guard await capturePolicy.screens else { return }
        guard !(await state.isOptedOut) else { return }
        var values: JSONObject = [:]
        let extras = await MainActor.run {
            var result = automaticProperties.properties(event: "$screen")
            if let scheme = dependencies.colorScheme(), ["dark", "light"].contains(scheme) {
                result["$prefers_color_scheme"] = .string(scheme)
            }
            return result
        }
        values.merge(extras) { _, extra in extra }
        values.merge(json(properties)) { _, explicit in explicit }
        values["$screen_name"] = .string(name)
        values["$screen_id"] = .string(dependencies.uuid.uuid())
        await captureCore("$screen", properties: values)
    }

    #if canImport(UIKit)
    @MainActor
    func captureInteraction(_ name: String, element: NSObject, properties: [String: Any]) {
        let automatic = json(properties)
        let declarative = founderHQDeclarativeProperties(
            element as? UIView ?? (element as? UIBarButtonItem)?.customView
        )
        _ = enqueueInvocation { [weak self] in
            guard let self else { return }
            await initialization?.value
            guard !(await state.isOptedOut), elementCaptureEnabled,
                  name != "$rageclick" || rageClickCaptureEnabled else { return }
            let extras = await MainActor.run {
                let description: JSONObject?
                if case .array(let elements) = automatic["$elements"],
                   case .object(let first) = elements.first { description = first }
                else { description = nil }
                return self.automaticProperties.properties(
                    event: name, element: element, description: description,
                    declarative: declarative
                )
            }
            await captureCore(name, properties: automatic.merging(extras) { _, extra in extra })
        }
    }
    #endif

    public func register(_ properties: [String: Any]) {
        _ = enqueueInvocation { [weak self] in
            await self?.registerOperation(properties, once: false)
        }
    }

    public func registerAndWait(_ properties: [String: Any]) async {
        await enqueueInvocation { [weak self] in
            await self?.registerOperation(properties, once: false)
        }.value
    }

    private func registerOperation(_ properties: [String: Any], once: Bool) async {
        await initialization?.value
        await state.register(json(properties), once: once)
    }

    public func registerOnce(_ properties: [String: Any]) {
        _ = enqueueInvocation { [weak self] in
            await self?.registerOperation(properties, once: true)
        }
    }

    public func registerOnceAndWait(_ properties: [String: Any]) async {
        await enqueueInvocation { [weak self] in
            await self?.registerOperation(properties, once: true)
        }.value
    }

    public func unregister(_ key: String) {
        _ = enqueueInvocation { [weak self] in await self?.unregisterOperation(key) }
    }
    public func unregisterAndWait(_ key: String) async {
        await enqueueInvocation { [weak self] in await self?.unregisterOperation(key) }.value
    }
    private func unregisterOperation(_ key: String) async {
        await initialization?.value
        await state.unregister(key)
    }
    public func reset() {
        _ = enqueueInvocation { [weak self] in await self?.resetOperation() }
    }
    public func resetAndWait() async {
        await enqueueInvocation { [weak self] in await self?.resetOperation() }.value
    }
    private func resetOperation() async {
        await initialization?.value
        // The removal is built before the identity rotates, so it carries the
        // distinct ID of the person who signs out. It is the one event a reset
        // keeps: the rest of the queue goes, as before.
        let removed = await removePushDeviceFromCurrentPerson()
        let transition = await state.reset()
        await refreshSessionSnapshot()
        if transition.enabled {
            await revenueCatIdentity?.logIn(appUserID: transition.token)
            await captureCore("$set", properties: [
                "$purchase_attribution_token": .string(transition.token),
            ])
        }
        if removed { flushPushDeviceRemoval() }
    }

    /**
     Stores this device's push token: the `Data` from
     `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. It is
     always an APNs token, whatever provider the options name.

     The device is registered only for an identified person: the SDK sends the
     registration after `identify` and until `reset()`, and sends nothing for
     a guest. While a person is identified it sends the registration again on
     every app start, on a new token, and after `setPushEnabled`.

     The SDK never asks for the notification permission; it only reads the
     state the system reports. Leave `environment` out and the SDK reads it
     from the build's provisioning profile.
     */
    public func registerPushToken(
        _ deviceToken: Data,
        options: FounderHQPushRegistrationOptions = .apns()
    ) {
        registerPushToken(founderHQPushTokenHex(deviceToken), options: Self.apns(options))
    }

    public func registerPushTokenAndWait(
        _ deviceToken: Data,
        options: FounderHQPushRegistrationOptions = .apns()
    ) async {
        await registerPushTokenAndWait(
            founderHQPushTokenHex(deviceToken), options: Self.apns(options)
        )
    }

    private static func apns(
        _ options: FounderHQPushRegistrationOptions
    ) -> FounderHQPushRegistrationOptions {
        var options = options
        options.provider = .apns
        return options
    }

    /**
     Stores a token given as text: Firebase (`.fcm()`), Expo (`.expo()`), or an
     APNs token already in hex (`.apns()`). A token the server would refuse is
     not stored and not sent, and the SDK logs the reason (never the token).
     */
    public func registerPushToken(_ token: String, options: FounderHQPushRegistrationOptions) {
        _ = enqueueInvocation { [weak self] in
            await self?.registerPushTokenOperation(token, options: options)
        }
    }

    public func registerPushTokenAndWait(
        _ token: String,
        options: FounderHQPushRegistrationOptions
    ) async {
        await enqueueInvocation { [weak self] in
            await self?.registerPushTokenOperation(token, options: options)
        }.value
    }

    private func registerPushTokenOperation(
        _ token: String,
        options: FounderHQPushRegistrationOptions
    ) async {
        await initialization?.value
        let provider = options.provider
        let normalized: String
        switch founderHQNormalizedPushToken(token, provider: provider) {
        case .valid(let value):
            normalized = value
        case .invalid(let reason):
            // The token is never logged, valid or not.
            NSLog("[FounderHQEvents] registerPushToken ignored the token: %@", reason)
            return
        }
        let previous = await state.pushDevice
        if previous?.token != normalized || previous?.provider != provider {
            // A refreshed token replaces the old one instead of leaving it behind.
            _ = await removePushDeviceFromCurrentPerson()
        }
        await state.storePushToken(
            normalized,
            provider: provider,
            appId: options.appId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            environment: options.environment
                ?? (provider == .apns ? FounderHQPushEnvironmentDetector.detect() : nil),
            enabled: options.enabled
        )
        if let permission = options.permission {
            await registerStoredPushDevice(permission: .known(permission))
        } else {
            await registerStoredPushDevice()
        }
    }

    /**
     The app's own push switch for this device. `false` stops every push to
     it; the token stays registered. The SDK always stores the switch and
     sends it only while a person is identified; otherwise it travels with the
     next registration. `reset()` clears it.
     */
    public func setPushEnabled(_ enabled: Bool) {
        _ = enqueueInvocation { [weak self] in await self?.setPushEnabledOperation(enabled) }
    }
    public func setPushEnabledAndWait(_ enabled: Bool) async {
        await enqueueInvocation { [weak self] in await self?.setPushEnabledOperation(enabled) }.value
    }
    private func setPushEnabledOperation(_ enabled: Bool) async {
        await initialization?.value
        await state.setPushEnabled(enabled)
        await registerStoredPushDevice()
    }

    /// Removes this device from the current person and forgets the token.
    public func unregisterPushToken() {
        _ = enqueueInvocation { [weak self] in await self?.unregisterPushTokenOperation() }
    }
    public func unregisterPushTokenAndWait() async {
        await enqueueInvocation { [weak self] in await self?.unregisterPushTokenOperation() }.value
    }
    private func unregisterPushTokenOperation() async {
        await initialization?.value
        let removed = await removePushDeviceFromCurrentPerson()
        await state.forgetPushToken()
        if removed { flushPushDeviceRemoval() }
    }

    /**
     Reports that the user opened the app from a notification, and returns the
     notification's link (`fhqLink`) or nil. Call it only if you turned
     `capturePushNotificationOpened` off. While that is on, the SDK reports
     the open by itself, and this method reports nothing: it only returns the
     link.

     Only `fhqOutboundMessageId` and `fhqLink` are read from `userInfo`. A
     payload with neither is not a FounderHQ notification: the SDK reports
     nothing for it and returns nil, so you can pass every notification.
     */
    @discardableResult
    public func capturePushNotificationOpened(
        userInfo: [AnyHashable: Any],
        properties: [String: Any] = [:]
    ) -> String? {
        let payload = FounderHQPushPayload(userInfo: userInfo)
        guard payload.isFounderHQ else { return nil }
        guard !configuration.capturePushNotificationOpened else {
            founderHQDebugLog(configuration.debug) {
                "capturePushNotificationOpened(userInfo:) reported nothing: the SDK reports opens by itself"
            }
            return payload.link
        }
        return pushNotificationOpened(payload, properties: properties)
    }

    @discardableResult
    func pushNotificationOpened(
        _ payload: FounderHQPushPayload,
        properties: [String: Any]
    ) -> String? {
        var properties = properties
        if let messageId = payload.messageId {
            properties[FounderHQProtocolConstants.PushProperty.messageId] = messageId
        }
        capture(FounderHQProtocolConstants.pushNotificationOpenedEvent, properties: properties)
        if let handler = configuration.onPushNotificationOpened {
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(payload) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(payload) } }
            }
        }
        return payload.link
    }
    public func optIn() {
        _ = enqueueInvocation { [weak self] in await self?.setOptedOutOperation(false) }
    }
    public func optInAndWait() async {
        await enqueueInvocation { [weak self] in await self?.setOptedOutOperation(false) }.value
    }
    public func optOut() {
        _ = enqueueInvocation { [weak self] in await self?.setOptedOutOperation(true) }
    }
    public func optOutAndWait() async {
        await enqueueInvocation { [weak self] in await self?.setOptedOutOperation(true) }.value
    }
    private func setOptedOutOperation(_ optedOut: Bool) async {
        await initialization?.value
        await state.setOptedOut(optedOut)
        await refreshSessionSnapshot()
        // Registrations were held back while the person was opted out.
        if !optedOut { await registerStoredPushDevice() }
    }
    public func isOptedOut() async -> Bool { await state.isOptedOut }
    public func getDistinctId() async -> String { await state.distinctId }

    public func getSessionId() async -> String {
        let result = await state.sessionIdentity()
        if result.rotated, await capturePolicy.sessions {
            await captureCore("$session_start", properties: [:])
        }
        await refreshSessionSnapshot()
        return result.identity.sessionId
    }

    public func purchaseAttribution() async -> FounderHQPurchaseAttribution {
        await initialization?.value
        let token = await state.enablePurchaseAttribution()
        await captureCore("$set", properties: [
            "$purchase_attribution_token": .string(token),
        ])
        return FounderHQPurchaseAttribution(
            appAccountToken: UUID(uuidString: token)!,
            obfuscatedExternalAccountId: token,
            revenueCatAppUserID: token
        )
    }

    public func preparePurchase(
        source: FounderHQPurchaseSource
    ) async throws -> FounderHQPreparedPurchase {
        let tokenBox = FounderHQLockedBox<String>()
        let preparedBox = FounderHQLockedBox<FounderHQPreparedPurchase>()
        let outcome = await withCheckedContinuation { continuation in
            let once = FounderHQOneShotPreparation(continuation)
            Task { [weak self] in
                guard let self else { return }
                let generated = dependencies.uuid.uuid()
                guard UUID(uuidString: generated) != nil else {
                    once.resume(.failed(FounderHQPurchaseError.invalidPurchaseContext))
                    return
                }
                let token = tokenBox.getOrSet(generated)
                await initialization?.value
                let identity = await state.purchasePreparationIdentity()
                let accountProperties = controlAccountProperties(identity.account)
                let uuid = UUID(uuidString: token)!
                let prepared = FounderHQPreparedPurchase(
                    purchaseContextToken: uuid,
                    appAccountToken: source == .storeKit ? uuid : nil,
                    obfuscatedExternalAccountId: source == .playBilling ? token : nil,
                    source: source,
                    accountProperties: accountProperties
                )
                preparedBox.set(prepared)
                var automatic = dependencies.platformFacts.properties()
                automatic["$platform"] = .string("ios")
                automatic["$device_id"] = .string(identity.anonymousId)
                automatic["$purchase_attribution_token"] = .string(
                    identity.purchaseAttributionToken
                )
                var properties = automatic
                    .merging([
                        "purchase_context_token": .string(token),
                        "source": .string(
                            wirePurchaseSource(source)
                        ),
                        "mobile_identity_token": .string(
                            identity.purchaseAttributionToken
                        ),
                        "prepared_at": .string(isoString(dependencies.clock.now())),
                        "prepared_acknowledgement": .string("UNACKNOWLEDGED"),
                    ]) { _, explicit in explicit }
                    .merging(accountProperties) { _, snapshot in snapshot }
                for key in ["$lib", "$lib_version", "$session_id", "$window_id"] {
                    properties.removeValue(forKey: key)
                }
                await state.enqueueInBackground(EventPayload(
                    uuid: dependencies.uuid.uuid(),
                    event: "$mobile_purchase_prepared",
                    distinctId: identity.distinctId,
                    timestamp: isoString(dependencies.clock.now()),
                    properties: properties,
                    sessionId: identity.sessionId,
                    options: .init(
                        processPersonProfile: shouldProcessPersonProfile(
                            configuration.personProfiles,
                            identified: identity.identified
                        )
                    )
                ))
                once.resume(.completed(.init(
                    prepared: prepared,
                    acknowledged: await self.flushCore(respectRetryLadder: false)
                )))
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + max(0, configuration.purchasePrepareTimeout)
            ) {
                // The injected UUID provider keeps this timeout path
                // deterministic under the golden conformance harness.
                let token = tokenBox.getOrSet(
                    self.dependencies.uuid.uuid().lowercased()
                )
                let uuid = UUID(uuidString: token) ?? UUID()
                let fallback = FounderHQPreparedPurchase(
                    purchaseContextToken: uuid,
                    appAccountToken: source == .storeKit ? uuid : nil,
                    obfuscatedExternalAccountId: source == .playBilling ? token : nil,
                    source: source,
                    accountProperties: [:]
                )
                preparedBox.setIfEmpty(fallback)
                once.resume(.completed(.init(
                    prepared: preparedBox.get() ?? fallback,
                    acknowledged: false
                )))
            }
        }
        switch outcome {
        case .failed(let error):
            throw error
        case .completed(let result):
            // Durability is best-effort here: a hung store may lose this snapshot on process
            // death, but checkout must never block and UNACKNOWLEDGED can be persisted later.
            Task {
                await state.markPreparedAcknowledgement(
                    token: result.prepared.purchaseContextToken.uuidString.lowercased(),
                    acknowledged: result.acknowledged
                )
            }
            return result.prepared
        }
    }

    /**
     Wraps a RevenueCat purchase closure without taking a package dependency on
     RevenueCat. The returned value is passed through unchanged; its
     `transaction`/`storeTransaction` value is read using RevenueCat's public
     field names and converted into the typed FounderHQ claim event.
     */
    public func purchaseWithRevenueCat<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let prepared = try await preparePurchase(source: .revenueCat)
        let result = try await operation()
        guard let transaction = reflectedField(
            result,
            names: ["transaction", "storeTransaction"]
        ), let purchase = reflectedRevenueCatPurchase(transaction) else {
            throw FounderHQPurchaseError.missingProviderReference
        }
        await captureRevenueCatClaim(
            purchase,
            token: prepared.purchaseContextToken.uuidString.lowercased(),
            intent: "PURCHASE",
            accountProperties: prepared.accountProperties
        )
        return result
    }

    public func claimRevenueCatSubscription<T: Sendable>(
        _ transaction: T,
        confirmation: FounderHQRevenueClaimConfirmation
    ) async throws -> FounderHQSubscriptionClaimReceipt {
        guard confirmation == .moveFutureRevenue,
              let purchase = reflectedRevenueCatPurchase(transaction)
        else { throw FounderHQPurchaseError.missingProviderReference }
        let claimId = dependencies.uuid.uuid()
        let identity = await state.identityForCapture()
        await captureRevenueCatClaim(
            purchase,
            token: claimId,
            intent: "TRANSFER",
            accountProperties: controlAccountProperties(identity.identity.account)
        )
        return .init(claimId: claimId, status: "queued")
    }

    public func observePurchase(
        _ purchase: FounderHQObservedPurchase,
        prepared: FounderHQPreparedPurchase
    ) async throws {
        guard prepared.source == purchase.source else {
            throw FounderHQPurchaseError.missingProviderReference
        }
        await captureObservedPurchaseClaim(
            purchase,
            token: prepared.purchaseContextToken.uuidString.lowercased(),
            intent: "PURCHASE",
            accountProperties: prepared.accountProperties
        )
    }

    public func claimSubscription(
        _ purchase: FounderHQObservedPurchase,
        confirmation: FounderHQRevenueClaimConfirmation
    ) async throws -> FounderHQSubscriptionClaimReceipt {
        guard confirmation == .moveFutureRevenue else {
            throw FounderHQPurchaseError.missingProviderReference
        }
        let claimId = dependencies.uuid.uuid()
        let identity = await state.identityForCapture()
        await captureObservedPurchaseClaim(
            purchase,
            token: claimId,
            intent: "TRANSFER",
            accountProperties: controlAccountProperties(identity.identity.account)
        )
        return .init(claimId: claimId, status: "queued")
    }

    private func captureObservedPurchaseClaim(
        _ purchase: FounderHQObservedPurchase,
        token: String,
        intent: String,
        accountProperties: JSONObject
    ) async {
        var properties: JSONObject = [
            "purchase_context_token": .string(token),
            "intent": .string(intent),
            "source": .string(wirePurchaseSource(purchase.source)),
            "store": .string(purchase.store.uppercased()),
            "confirmation": .string(
                intent == "PURCHASE" ? "new_purchase" : "move_future_revenue"
            ),
        ]
        if let value = purchase.transactionId {
            properties["provider_transaction_id"] = .string(value)
        }
        if let value = purchase.subscriptionId {
            properties["provider_subscription_id"] = .string(value)
        }
        if let value = purchase.purchaseToken {
            properties["provider_purchase_token"] = .string(value)
        }
        if let value = purchase.productId {
            properties["product_id"] = .string(value)
        }
        if let value = purchase.purchasedAt {
            properties["provider_purchased_at"] = .string(value)
        }
        await captureControlCore(
            "$mobile_purchase_claim",
            properties: properties,
            accountProperties: accountProperties
        )
    }

    private func captureRevenueCatClaim(
        _ purchase: FounderHQReflectedRevenueCatPurchase,
        token: String,
        intent: String,
        accountProperties: JSONObject
    ) async {
        var properties: JSONObject = [
            "purchase_context_token": .string(token),
            "intent": .string(intent),
            "source": .string("REVENUECAT"),
            "store": .string(purchase.store),
            "confirmation": .string(
                intent == "PURCHASE" ? "new_purchase" : "move_future_revenue"
            ),
        ]
        if let value = purchase.transactionId {
            properties["provider_transaction_id"] = .string(value)
        }
        if let value = purchase.subscriptionId {
            properties["provider_subscription_id"] = .string(value)
        }
        if let value = purchase.purchaseToken {
            properties["provider_purchase_token"] = .string(value)
        }
        if let value = purchase.productId {
            properties["product_id"] = .string(value)
        }
        if let value = purchase.purchasedAt {
            properties["provider_purchased_at"] = .string(value)
        }
        await captureControlCore(
            "$mobile_purchase_claim",
            properties: properties,
            accountProperties: accountProperties
        )
    }

    #if canImport(StoreKit)
    @available(iOS 15.0, macOS 12.0, *)
    public func purchase(
        _ product: StoreKit.Product,
        options: Set<StoreKit.Product.PurchaseOption> = []
    ) async throws -> StoreKit.Product.PurchaseResult {
        let prepared = try await preparePurchase(source: .storeKit)
        var purchaseOptions = options
        purchaseOptions.insert(.appAccountToken(prepared.purchaseContextToken))
        let result = try await product.purchase(options: purchaseOptions)
        if case let .success(verification) = result {
            await observePurchase(verification, prepared: prepared)
        }
        return result
    }

    @available(iOS 15.0, macOS 12.0, *)
    public func observePurchase(
        _ result: StoreKit.VerificationResult<StoreKit.Transaction>,
        prepared: FounderHQPreparedPurchase
    ) async {
        guard prepared.source == .storeKit,
              case let .verified(transaction) = result
        else { return }
        await captureStoreKitClaim(
            transaction,
            token: prepared.purchaseContextToken.uuidString.lowercased(),
            intent: "PURCHASE",
            accountProperties: prepared.accountProperties
        )
    }

    @available(iOS 15.0, macOS 12.0, *)
    public func claimSubscription(
        _ result: StoreKit.VerificationResult<StoreKit.Transaction>,
        confirmation: FounderHQRevenueClaimConfirmation
    ) async throws -> FounderHQSubscriptionClaimReceipt {
        guard confirmation == .moveFutureRevenue,
              case let .verified(transaction) = result
        else { throw FounderHQPurchaseError.unverifiedTransaction }
        let claimId = dependencies.uuid.uuid()
        let identity = await state.identityForCapture()
        await captureStoreKitClaim(
            transaction,
            token: claimId,
            intent: "TRANSFER",
            accountProperties: controlAccountProperties(identity.identity.account)
        )
        return .init(claimId: claimId, status: "queued")
    }

    @available(iOS 15.0, macOS 12.0, *)
    private func captureStoreKitClaim(
        _ transaction: StoreKit.Transaction,
        token: String,
        intent: String,
        accountProperties: JSONObject
    ) async {
        await captureControlCore("$mobile_purchase_claim", properties: [
            "purchase_context_token": .string(token),
            "intent": .string(intent),
            "source": .string("STOREKIT"),
            "store": .string("APP_STORE"),
            "provider_transaction_id": .string(String(transaction.id)),
            "provider_subscription_id": .string(String(transaction.originalID)),
            "product_id": .string(transaction.productID),
            "provider_purchased_at": .string(isoString(transaction.purchaseDate)),
            "confirmation": .string(intent == "PURCHASE" ? "new_purchase" : "move_future_revenue"),
        ], accountProperties: accountProperties)
    }
    #endif

    public func applyRemoteConfig(_ config: [String: Any]) async {
        await initialization?.value
        await applyRemoteConfigCore(config)
    }

    /** Refetches operator capture settings through the authenticated config endpoint. */
    @discardableResult
    public func refreshRemoteConfig() async -> Bool {
        await initialization?.value
        return await fetchRemoteConfig()
    }

    /**
     Applies one operator config payload.

     The operator's settings win, in both directions, exactly as they do for
     `capture_screens` and `capture_lifecycle`. `captureElementInteractions`
     is the default that holds until the settings arrive, not a ceiling. A
     shipped app cannot be rebuilt on demand, so an operator must be able to
     switch a tap stream both off for every install at once and on for an app
     that shipped with the wrong default.

     `autocapture` may also arrive as a rules object rather than a boolean.
     Only a boolean changes anything here; a rules object leaves capture as
     the app set it, because iOS does not evaluate the web selector rules.
     */
    private func applyRemoteConfigCore(_ config: [String: Any]) async {
        let previousLifecycle = await capturePolicy.lifecycle
        let previousScreens = await capturePolicy.screens
        let previousElements = await capturePolicy.elements
        let elements = config["autocapture"] as? Bool
            ?? configuration.captureElementInteractions
        let rageClicks = (config["capture_rageclicks"] as? Bool ?? true) && elements
        await capturePolicy.apply(
            lifecycle: config["capture_lifecycle"] as? Bool ?? configuration.captureLifecycle,
            screens: config["capture_screens"] as? Bool ?? configuration.captureScreens,
            sessions: config["capture_sessions"] as? Bool ?? configuration.captureSessions,
            elements: elements,
            rageClicks: rageClicks
        )
        interactionSnapshot.set(elements: elements, rageClicks: rageClicks)
        let lifecycle = await capturePolicy.lifecycle
        if previousLifecycle && !lifecycle {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        } else if !previousLifecycle && lifecycle {
            startLifecycleCapture()
        }
        let screens = await capturePolicy.screens
        if !previousScreens && screens {
            await installScreenCaptureIfNeeded()
        }
        if !previousElements && elements {
            await installInteractionCaptureIfNeeded()
        }
        var disabled = Set<String>()
        if !(await capturePolicy.sessions) { disabled.insert("$session_start") }
        if !(await capturePolicy.screens) { disabled.insert("$screen") }
        if !elements { disabled.insert("$autocapture") }
        if !rageClicks { disabled.insert("$rageclick") }
        if !lifecycle {
            disabled.insert("$application_opened")
            disabled.insert("$application_backgrounded")
        }
        await state.remove(eventsNamed: disabled)
    }

    public func recordLifecycleAndWait(_ lifecycle: String) async {
        await enqueueInvocation { [weak self] in
            await self?.recordLifecycleOperation(lifecycle)
        }.value
    }

    private func recordLifecycleOperation(_ lifecycle: String) async {
        await initialization?.value
        guard await capturePolicy.lifecycle else { return }
        if lifecycle == "active" {
            await captureCore("$application_opened", properties: [:])
        } else if lifecycle == "background" {
            await captureCore("$application_backgrounded", properties: [:])
        }
    }

    public func captureDeepLink(_ url: URL) {
        var properties = campaignProperties(url)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        properties["$deep_link_url"] = components?.url?.absoluteString ?? url.path
        capture("$application_opened", properties: properties)
    }

    /**
     Sends what is queued now.

     An app that calls this is usually about to be killed, or is a test, so
     the retry ladder stands aside: waiting events go out with the rest.
     The flushes the SDK schedules for itself honour the ladder instead —
     see `flushOnSchedule`.
     */
    @discardableResult
    public func flush() async -> Bool {
        await initialization?.value
        await startPushRegistration?.value
        await invocationSnapshot()?.value
        return await flushCore(respectRetryLadder: false)
    }

    /** The timer, the flushAt threshold, and going to background. */
    @discardableResult
    func flushOnSchedule() async -> Bool {
        await initialization?.value
        await invocationSnapshot()?.value
        return await flushCore(respectRetryLadder: true)
    }

    private let flushGate = FlushGate()

    private func flushCore(respectRetryLadder: Bool) async -> Bool {
        // Timer, lifecycle, and manual flushes share one in-flight request so
        // two callers can never send the same queue head or rotate identity
        // twice.
        await flushGate.run {
            await self.flushBatch(respectRetryLadder: respectRetryLadder)
        }
    }

    private func flushBatch(respectRetryLadder: Bool) async -> Bool {
        // The ingest endpoint rejects batches over 100 items; an unclamped
        // flushAt above that would retry the same oversized batch forever.
        let events = await state.peek(
            limit: min(100, max(1, configuration.flushAt)),
            respectRetryLadder: respectRetryLadder
        )
        guard !events.isEmpty else { return true }
        let envelope = EventEnvelope(
            sentAt: isoString(dependencies.clock.now()),
            batch: events
        )
        var request = URLRequest(url: configuration.host.appendingPathComponent("i/v2/e"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "\(Self.sdkName)/\(Self.sdkVersion)",
            forHTTPHeaderField: "FounderHq-Sdk-Info"
        )
        do {
            request.httpBody = try JSONEncoder().encode(envelope)
            let response = try await dependencies.transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                await countFailedAttempt(
                    events.map(\.uuid),
                    reason: "the ingest API answered \(response.statusCode)"
                )
                return false
            }
            let ack = try JSONDecoder().decode(EventAck.self, from: response.data)
            let settled = Set(
                ack.results.compactMap { uuid, result in
                    result.result == "retry" ? nil : uuid
                }
            )
            await state.remove(uuids: settled)
            if let directive = ack.directives?.first(where: { $0.type == "rotate_distinct_id" }),
               let identify = events.first(where: { $0.event == "$identify" }) {
                await state.retryIdentify(identify, directiveId: directive.distinctId)
            }
            // Anything the API neither accepted nor rejected stays queued, so it
            // counts as a failed attempt too. Without that an event the API
            // silently omits would sit in the queue with no attempt ever spent.
            let unsettled = events.map(\.uuid).filter { !settled.contains($0) }
            guard unsettled.isEmpty else {
                await countFailedAttempt(unsettled, reason: "the ingest API asked for a retry")
                return false
            }
            return true
        } catch {
            await countFailedAttempt(
                events.map(\.uuid),
                reason: "the batch never reached the ingest API"
            )
            return false
        }
    }

    /**
     Spends one delivery attempt per event, moves each one on to its next rung
     of the retry ladder, and reports the ones that ran off the end. A waiting
     event is skipped by later flushes instead of blocking them, so a fresh
     event still goes out while an older one serves its wait.
     */
    private func countFailedAttempt(_ uuids: [String], reason: String) async {
        let dropped = await state.countFailedAttempt(uuids: uuids)
        guard !dropped.isEmpty else { return }
        founderHQDebugLog(configuration.debug) {
            """
            dropped \(dropped.count) event(s) after \(max(0, configuration.maxRetries) + 1) \
            delivery attempts: \(reason)
            """
        }
    }

    public func close() async {
        _ = await flush()
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func persistedStateData() async -> Data? { await state.persistedData() }

    private func captureCore(_ name: String, properties: JSONObject) async {
        guard isAllowedEvent(name), !(await state.isOptedOut) else { return }
        let captureIdentity = await state.identityForCapture()
        if captureIdentity.rotated,
           await capturePolicy.sessions,
           name != "$session_start" {
            await captureCore("$session_start", properties: [:])
        }
        let identity = captureIdentity.identity
        sessionSnapshot.set(identity.sessionId)
        let event = envelope(
            name,
            identity: identity,
            properties: properties,
            registered: await state.registered,
            attributionToken: identity.purchaseAttributionEnabled,
            account: .current
        )
        await state.enqueue(event)
        if await state.queueCount >= configuration.flushAt {
            _ = await flushCore(respectRetryLadder: true)
        }
    }

    private func captureControlCore(
        _ name: String,
        properties: JSONObject,
        accountProperties: JSONObject
    ) async {
        guard !(await state.isOptedOut) else { return }
        let identity = (await state.identityForCapture()).identity
        await state.enqueue(envelope(
            name,
            identity: identity,
            properties: properties,
            attributionToken: true,
            account: .snapshot(accountProperties)
        ))
    }

    /// Which account facts an envelope carries.
    private enum EnvelopeAccount {
        /// None: a push device event.
        case none
        /// The account in place now. It wins over every other property.
        case current
        /// The account as it was when a purchase was prepared.
        case snapshot(JSONObject)
    }

    /**
     The one place an event envelope is built. Ordinary events, purchase
     control events, and push device events differ only in the arguments. It
     reads the identity it is given and never rotates a session: the caller
     decides whether this event is activity.
     */
    private func envelope(
        _ name: String,
        identity: CaptureIdentity,
        properties: JSONObject,
        registered: JSONObject = [:],
        attributionToken: Bool,
        account: EnvelopeAccount,
        uuid: String? = nil,
        timestamp: String? = nil,
        person: (distinctId: String, identified: Bool)? = nil
    ) -> EventPayload {
        var automatic = dependencies.platformFacts.properties()
        automatic["$platform"] = .string("ios")
        automatic["$device_id"] = .string(identity.anonymousId)
        if attributionToken {
            automatic["$purchase_attribution_token"] = .string(identity.purchaseAttributionToken)
        }
        var accountProperties: JSONObject = [:]
        var dropsContextToken = false
        switch account {
        case .none:
            break
        case .current:
            if let account = identity.account {
                accountProperties["$groups"] = .object(["account": .string(account.key)])
                accountProperties["$account_span_id"] = .string(account.spanId)
                if let contextToken = account.contextToken {
                    accountProperties["$account_context_token"] = .string(contextToken)
                } else {
                    dropsContextToken = true
                }
            }
        case .snapshot(let snapshot):
            accountProperties = snapshot
        }
        var merged = automatic
            .merging(registered) { _, registered in registered }
            .merging(properties) { _, explicit in explicit }
            .merging(accountProperties) { _, account in account }
        if dropsContextToken { merged.removeValue(forKey: "$account_context_token") }
        for key in ["$lib", "$lib_version", "$session_id", "$window_id"] {
            merged.removeValue(forKey: key)
        }
        return EventPayload(
            uuid: uuid ?? dependencies.uuid.uuid(),
            event: name,
            distinctId: person?.distinctId ?? identity.distinctId,
            timestamp: timestamp ?? isoString(dependencies.clock.now()),
            properties: merged,
            sessionId: identity.sessionId,
            options: .init(
                processPersonProfile: shouldProcessPersonProfile(
                    configuration.personProfiles,
                    identified: person?.identified ?? identity.identified
                )
            )
        )
    }

    /// Where a registration gets the notification permission from.
    private enum PushPermissionSource {
        /// Ask the system now.
        case system
        /// The app gave it, or the caller already asked the system.
        case known(FounderHQPushPermission?)
    }

    /**
     Sends the stored token for the current person, and only for an identified
     one: a guest gets no device. A registration moves "last seen" on the
     server, so each start sends one. A registration that is the same as the
     last one this process queued is not sent again.

     It runs only on the invocation chain, so nothing changes the person or
     the token between its steps.
     */
    private func registerStoredPushDevice(permission: PushPermissionSource = .system) async {
        guard let device = await state.pushDevice,
              let token = device.token, let provider = device.provider,
              await state.isIdentified else { return }
        // The app registers this device for this person now. A removal of the
        // same device from the same person that still waits is out of date:
        // sent later, it would take the device away again. Before the opt-out
        // check, because an opted-out person sends no registration to undo it.
        await state.dropPushRemovals(token: token, provider: provider)
        guard !(await state.isOptedOut) else { return }
        typealias Key = FounderHQProtocolConstants.PushProperty
        var properties: JSONObject = [
            Key.token: .string(token),
            Key.provider: .string(provider.rawValue),
            Key.platform: .string(Self.pushPlatform),
        ]
        if let appId = device.appId { properties[Key.appId] = .string(appId) }
        if let environment = device.environment {
            properties[Key.environment] = .string(environment.rawValue)
        }
        if let enabled = device.enabled { properties[Key.enabled] = .bool(enabled) }
        let seen: FounderHQPushPermission?
        switch permission {
        case .system: seen = await systemPushPermission()
        case .known(let value): seen = value
        }
        if let seen { properties[Key.permission] = .string(seen.rawValue) }
        await state.enqueuePushRegistration(pushControlEvent(
            FounderHQProtocolConstants.pushDeviceRegisteredEvent,
            identity: await state.identitySnapshot(),
            properties: properties
        ), registration: properties)
    }

    /**
     The registration of a start. The permission is read first, outside the
     invocation chain, so a slow answer from the system delays no other call.
     The registration itself then takes its turn on the chain.
     */
    private func registerStoredPushDeviceAtStart() async {
        let permission = await systemPushPermission()
        await enqueueInvocation { [weak self] in
            await self?.registerStoredPushDevice(permission: .known(permission))
        }.value
    }

    /// Whether a start has a registration to send: a token, for an identified person.
    private func hasPushDeviceToRegister() async -> Bool {
        guard let device = await state.pushDevice, device.token != nil, device.provider != nil
        else { return false }
        return await state.isIdentified
    }

    /// This SDK's own `$push_platform`.
    static let pushPlatform = "ios"

    /**
     Takes the stored token away from the person in place now. Nothing was
     registered for a guest, so there is nothing to remove for one. The
     removal is sent even while opted out. Returns whether one was queued.
     */
    private func removePushDeviceFromCurrentPerson() async -> Bool {
        // Written down first: the queue can lose an event (age, size,
        // retries), the list of pending removals cannot.
        guard let removal = await state.beginPushRemoval() else { return false }
        await state.enqueue(pushRemovedEvent(removal, identity: await state.identitySnapshot()))
        return true
    }

    private func pushRemovedEvent(
        _ removal: FounderHQPendingPushRemoval,
        identity: CaptureIdentity
    ) -> EventPayload {
        typealias Key = FounderHQProtocolConstants.PushProperty
        var properties: JSONObject = [Key.token: .string(removal.token)]
        if let provider = removal.provider {
            properties[Key.provider] = .string(provider.rawValue)
        }
        return pushControlEvent(
            FounderHQProtocolConstants.pushDeviceRemovedEvent,
            identity: identity,
            properties: properties,
            uuid: removal.uuid,
            // The time of the sign-out, on every send.
            timestamp: removal.timestamp,
            // A removal is only ever written for an identified person.
            person: (removal.distinctId, true)
        )
    }

    /**
     On a start, every removal the server has not accepted goes to the front
     of the queue again, before any registration. The queue copy of an older
     attempt is replaced, so a removal is never in the queue twice. It keeps
     the time of the sign-out, however late it goes.
     */
    private func requeuePendingPushRemovals() async {
        let pending = await state.pendingPushRemovals
        guard !pending.isEmpty else { return }
        let identity = await state.identitySnapshot()
        await state.requeuePushRemovals(pending.map { pushRemovedEvent($0, identity: identity) })
    }

    /// A logout is often the last thing an app does, so the removal goes now.
    private func flushPushDeviceRemoval() {
        Task { [weak self] in _ = await self?.flushCore(respectRetryLadder: true) }
    }

    /**
     Push device events are instructions, not analytics: they skip `beforeSend`
     and super properties, so the token reaches ingest exactly as given and no
     hook sees it. The identity is read as it is: such an event never rotates
     a session and never counts as activity. The caller decides about opt-out.
     */
    private func pushControlEvent(
        _ name: String,
        identity: CaptureIdentity,
        properties: JSONObject,
        uuid: String? = nil,
        timestamp: String? = nil,
        person: (distinctId: String, identified: Bool)? = nil
    ) -> EventPayload {
        envelope(
            name,
            identity: identity,
            properties: properties,
            attributionToken: false,
            account: .none,
            uuid: uuid,
            timestamp: timestamp,
            person: person
        )
    }

    /**
     The permission the system reports, read without a prompt. A process with
     no app bundle behind it (a test runner, a command line tool) has no
     notification centre to ask, and asking would raise.
     */
    private func systemPushPermission() async -> FounderHQPushPermission? {
        #if canImport(UserNotifications)
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".appex") else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return founderHQPushPermission(authorizationStatus: settings.authorizationStatus.rawValue)
        #else
        return nil
        #endif
    }

    @discardableResult
    private func enqueueInvocation(
        _ operation: @escaping () async -> Void
    ) -> Task<Void, Never> {
        invocationLock.lock()
        let previous = invocationTail
        let task = Task {
            await previous?.value
            await operation()
        }
        invocationTail = task
        invocationLock.unlock()
        return task
    }

    private func invocationSnapshot() -> Task<Void, Never>? {
        invocationLock.lock()
        let task = invocationTail
        invocationLock.unlock()
        return task
    }

    private func startTimer() {
        guard configuration.flushInterval > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            timer = Timer.scheduledTimer(
                withTimeInterval: configuration.flushInterval,
                repeats: true
            ) { [weak self] _ in Task { _ = await self?.flushOnSchedule() } }
        }
    }

    private func startLifecycleCapture() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.recordLifecycleAndWait("active") }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.recordLifecycleAndWait("background")
                _ = await self.flushOnSchedule()
            }
        })
        #endif
    }

    private func armAutomaticCapture() async {
        if await capturePolicy.lifecycle { startLifecycleCapture() }
        // Track navigation even while screen event emission is disabled.
        await installScreenCaptureIfNeeded()
        await installInteractionCaptureIfNeeded()
        installTracingHeadersIfNeeded()
    }

    private func installInteractionCaptureIfNeeded() async {
        #if canImport(UIKit)
        // The effective policy, not the shipped default: remote config can
        // switch element capture on for an app that shipped with it off, and
        // the swizzle has to be in place before the next tap.
        if await capturePolicy.elements, !elementCaptureInstalled {
            elementCaptureInstalled = true
            await MainActor.run {
                FounderHQInteractionCapture.install(client: self, debug: configuration.debug)
            }
        }
        #endif
    }

    /**
     Hooks the notification centre delegate, on the main thread and without a
     wait when the SDK is created there. Only the app's own configuration
     decides this, so nothing has to load first: with
     `capturePushNotificationOpened` off, nothing is hooked.
     */
    private func installPushCapture() {
        #if canImport(UIKit) && canImport(UserNotifications)
        guard configuration.capturePushNotificationOpened else { return }
        let debug = configuration.debug
        if Thread.isMainThread {
            FounderHQPushCapture.install(client: self, debug: debug)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                FounderHQPushCapture.install(client: self, debug: debug)
            }
        }
        #endif
    }

    private func installTracingHeadersIfNeeded() {
        guard let hostnames = configuration.tracingHeaders,
              !hostnames.isEmpty,
              !tracingHeadersInstalled
        else { return }
        tracingHeadersInstalled = true
        FounderHQNetworkTracing.install(
            client: self,
            hostnames: hostnames,
            ingestHostname: configuration.host.host,
            debug: configuration.debug
        )
    }

    /**
     The session id as of the last capture, read without awaiting the state
     actor. The URLSession hook runs on the caller's thread and must never
     block their request to look one up.
     */
    func currentTracingSessionId() -> String? { sessionSnapshot.current }

    /**
     Whether element capture may report right now, read without awaiting the
     capture-policy actor. The UIKit hooks run inside the frame UIKit is
     already drawing, so they must never suspend to ask.
     */
    var elementCaptureEnabled: Bool { interactionSnapshot.elements }

    /// Whether a run of taps on one element may raise `$rageclick`.
    var rageClickCaptureEnabled: Bool { interactionSnapshot.rageClicks }

    private func refreshSessionSnapshot() async {
        sessionSnapshot.set(await state.isOptedOut ? nil : await state.currentSessionId())
    }

    private func installScreenCaptureIfNeeded() async {
        guard !screenCaptureInstalled else { return }
        screenCaptureInstalled = true
        await MainActor.run {
            dependencies.screenCapture.install(client: self)
        }
    }

    private func loadCachedRemoteConfig() async {
        guard let raw = dependencies.storage.string(forKey: remoteConfigKey),
              let data = raw.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        await applyRemoteConfigCore(config)
    }

    private func fetchRemoteConfig() async -> Bool {
        guard configuration.remoteConfig else { return false }
        var request = URLRequest(
            url: configuration.host
                .appendingPathComponent("i")
                .appendingPathComponent("v1")
                .appendingPathComponent("analytics")
                .appendingPathComponent("config")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let response = try await dependencies.transport.send(request)
            guard (200..<300).contains(response.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let config = payload["config"] as? [String: Any]
            else { return false }
            let cached = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            dependencies.storage.set(String(decoding: cached, as: UTF8.self), forKey: remoteConfigKey)
            await applyRemoteConfigCore(config)
            return true
        } catch {
            return false
        }
    }

    private func captureInstallOrUpdate() async {
        let facts = dependencies.platformFacts.properties()
        guard case let .string(version)? = facts["$app_version"], !version.isEmpty else { return }
        let key = "com.founderhq.events.v2.installedVersion"
        let previous = dependencies.storage.string(forKey: key)
        dependencies.storage.set(version, forKey: key)
        if previous == nil {
            await captureCore("$application_installed", properties: ["$app_version": .string(version)])
        } else if previous != version {
            await captureCore("$application_updated", properties: [
                "$previous_app_version": .string(previous!),
                "$app_version": .string(version),
            ])
        }
    }
}

/// Serializes flushes: concurrent callers await the one in-flight request.
private actor FlushGate {
    private var inFlight: Task<Bool, Never>?

    func run(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await operation() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

private actor AutomaticCapturePolicy {
    private(set) var lifecycle: Bool
    private(set) var screens: Bool
    private(set) var sessions: Bool
    private(set) var elements: Bool
    private(set) var rageClicks: Bool

    init(lifecycle: Bool, screens: Bool, sessions: Bool, elements: Bool) {
        self.lifecycle = lifecycle
        self.screens = screens
        self.sessions = sessions
        self.elements = elements
        self.rageClicks = elements
    }

    func apply(
        lifecycle: Bool?,
        screens: Bool?,
        sessions: Bool?,
        elements: Bool?,
        rageClicks: Bool?
    ) {
        if let lifecycle { self.lifecycle = lifecycle }
        if let screens { self.screens = screens }
        if let sessions { self.sessions = sessions }
        if let elements { self.elements = elements }
        if let rageClicks { self.rageClicks = rageClicks }
    }
}

private actor EventsState {
    private let key: String
    private let storage: any FounderHQStorage
    private let writer: FounderHQStateWriter
    private let clock: any FounderHQClock
    private let uuid: any FounderHQUUIDProvider
    private let maxQueueSize: Int
    private let eventTTL: TimeInterval
    private let maxRetries: Int
    private let retryLadder: [TimeInterval?]
    private let debug: Bool
    private let beforeSend: FounderHQBeforeSend?
    private var value: PersistedState
    /**
     The last registration this process queued. Not stored: a new process
     sends one again. Cleared when that registration can no longer reach the
     server, or when the server may have lost the device since.
     */
    private var lastPushRegistration: PushRegistrationSignature?
    let wasRestored: Bool
    let needsSessionStart: Bool

    init(
        key: String,
        optOutByDefault: Bool,
        storage: any FounderHQStorage,
        writer: FounderHQStateWriter,
        clock: any FounderHQClock,
        uuid: any FounderHQUUIDProvider,
        maxQueueSize: Int,
        eventTTL: TimeInterval,
        maxRetries: Int,
        retryLadder: [TimeInterval?],
        debug: Bool,
        beforeSend: FounderHQBeforeSend?
    ) {
        self.key = key
        self.storage = storage
        self.writer = writer
        self.clock = clock
        self.uuid = uuid
        let boundedQueueSize = max(1, maxQueueSize)
        let boundedEventTTL = max(0, eventTTL)
        self.maxQueueSize = boundedQueueSize
        self.eventTTL = boundedEventTTL
        self.maxRetries = max(0, maxRetries)
        self.retryLadder = retryLadder
        self.debug = debug
        self.beforeSend = beforeSend
        if let data = storage.data(forKey: key),
           let restored = try? JSONDecoder().decode(PersistedState.self, from: data) {
            if isUUIDv7(restored.sessionId) {
                value = restored
                needsSessionStart = false
            } else {
                let now = clock.now()
                var repaired = restored
                repaired.sessionId = uuid.uuidV7(at: now)
                repaired.sessionStartedAt = now
                repaired.lastActivityAt = now
                value = repaired
                needsSessionStart = true
                storage.set(try? JSONEncoder().encode(repaired), forKey: key)
            }
            value.queue = pruneEventQueue(
                value.queue,
                now: clock.now(),
                maxQueueSize: boundedQueueSize,
                eventTTL: boundedEventTTL
            )
            value.deliverySchedule = Self.scheduleForNewProcess(
                schedule: value.deliverySchedule,
                legacyAttempts: value.deliveryAttempts,
                queue: value.queue
            )
            value.deliveryAttempts = nil
            storage.set(try? JSONEncoder().encode(value), forKey: key)
            wasRestored = true
        } else {
            let now = clock.now()
            let id = uuid.uuid()
            value = PersistedState(
                anonymousId: id,
                distinctId: id,
                identified: false,
                purchaseAttributionToken: id,
                purchaseAttributionEnabled: false,
                sessionId: uuid.uuidV7(at: now),
                sessionStartedAt: now,
                lastActivityAt: now,
                registered: [:],
                pendingSet: [:],
                pendingSetOnce: [:],
                optedOut: optOutByDefault,
                queue: [],
                account: nil,
                deliveryAttempts: nil
            )
            wasRestored = false
            needsSessionStart = true
            storage.set(try? JSONEncoder().encode(value), forKey: key)
        }
    }

    var isOptedOut: Bool { value.optedOut }
    var isIdentified: Bool { value.identified }
    var distinctId: String { value.distinctId }
    func currentSessionId() -> String { value.sessionId }
    var registered: JSONObject { value.registered }
    var queueCount: Int { value.queue.count }

    func identityForCapture() -> SessionIdentityResult {
        let rotated = rotateSessionIfNeeded()
        value.lastActivityAt = clock.now()
        persist()
        return .init(identity: identity, rotated: rotated)
    }

    /**
     The identity as it is: no session rotates and nothing counts as activity.
     Push device events read it this way, because they are instructions and
     not something the person did.
     */
    func identitySnapshot() -> CaptureIdentity { identity }

    func sessionIdentity() -> SessionIdentityResult {
        let rotated = rotateSessionIfNeeded()
        persist()
        return .init(identity: identity, rotated: rotated)
    }

    private var identity: CaptureIdentity {
        .init(
            anonymousId: value.anonymousId,
            distinctId: value.distinctId,
            identified: value.identified,
            purchaseAttributionToken: value.purchaseAttributionToken ?? value.anonymousId,
            purchaseAttributionEnabled: value.purchaseAttributionEnabled ?? false,
            sessionId: value.sessionId,
            account: value.account
        )
    }

    func identify(
        _ distinctId: String,
        properties: JSONObject,
        mode: FounderHQPersonProfiles,
        account: FounderHQAccountContext?
    ) -> IdentityTransition? {
        guard let id = normalizeDistinctId(distinctId), !value.optedOut else { return nil }
        if value.identified && value.distinctId != id {
            let guestID = uuid.uuid()
            value.anonymousId = guestID
            value.purchaseAttributionToken = guestID
            value.account = nil
            // The push switch belonged to the person before. The token stays.
            if var push = value.push {
                push.enabled = nil
                value.push = push.isEmpty ? nil : push
            }
            lastPushRegistration = nil
        }
        let groupSet = account.flatMap(applyAccount)
        let transition = IdentityTransition(
            anonymousId: value.anonymousId,
            set: mode == .never ? [:] : value.pendingSet.merging(properties) { _, explicit in explicit },
            setOnce: mode == .never ? [:] : value.pendingSetOnce,
            purchaseAttributionToken: value.purchaseAttributionToken ?? value.anonymousId,
            purchaseAttributionEnabled: value.purchaseAttributionEnabled ?? false,
            groupSet: groupSet
        )
        value.distinctId = id
        value.identified = true
        value.pendingSet = [:]
        value.pendingSetOnce = [:]
        persist()
        return transition
    }

    func personMutation(
        set: JSONObject,
        setOnce: JSONObject,
        mode: FounderHQPersonProfiles
    ) -> PersonMutation? {
        if mode == .never { return nil }
        if mode == .identifiedOnly && !value.identified {
            value.pendingSet.merge(set) { _, explicit in explicit }
            for (key, item) in setOnce where value.pendingSetOnce[key] == nil {
                value.pendingSetOnce[key] = item
            }
            persist()
            return nil
        }
        return .init(set: set, setOnce: setOnce)
    }

    func register(_ properties: JSONObject, once: Bool) {
        for (key, item) in properties where !once || value.registered[key] == nil {
            value.registered[key] = item
        }
        persist()
    }

    func unregister(_ key: String) { value.registered.removeValue(forKey: key); persist() }

    func setAccount(_ account: FounderHQAccountContext) -> JSONObject? {
        guard let properties = applyAccount(account) else { return nil }
        persist()
        return properties
    }

    func clearAccount() {
        value.account = nil
        persist()
    }

    func setAccountProperties(_ properties: JSONObject) -> JSONObject? {
        guard var account = value.account else { return nil }
        account.properties.merge(properties) { _, explicit in explicit }
        value.account = account
        persist()
        return account.properties
    }
    func setOptedOut(_ optedOut: Bool) {
        value.optedOut = optedOut
        if optedOut {
            // A device removal still goes out: opting out of analytics must
            // not leave a signed-out person's device registered.
            value.queue = value.queue.filter(Self.isPushDeviceRemoval)
            value.deliveryAttempts = nil
            pruneDeliverySchedule()
            lastPushRegistration = nil
        }
        persist()
    }

    var pushDevice: FounderHQPushDeviceState? { value.push }
    var pendingPushRemovals: [FounderHQPendingPushRemoval] { value.push?.pendingRemovals ?? [] }

    private static func isPushDeviceRemoval(_ event: EventPayload) -> Bool {
        event.event == FounderHQProtocolConstants.pushDeviceRemovedEvent
    }

    /// Stores the push state. An empty one is not kept.
    private func setPushDevice(_ device: FounderHQPushDeviceState) {
        var device = device
        if device.pendingRemovals?.isEmpty == true { device.pendingRemovals = nil }
        value.push = device.isEmpty ? nil : device
        persist()
    }

    /// The token and what came with it. A nil `enabled` keeps the stored switch.
    func storePushToken(
        _ token: String,
        provider: FounderHQPushProvider,
        appId: String?,
        environment: FounderHQPushEnvironment?,
        enabled: Bool?
    ) {
        setPushDevice(.init(
            token: token,
            provider: provider,
            appId: appId,
            environment: environment,
            enabled: enabled ?? value.push?.enabled,
            pendingRemovals: value.push?.pendingRemovals
        ))
    }

    func setPushEnabled(_ enabled: Bool) {
        var device = value.push ?? .init()
        device.enabled = enabled
        setPushDevice(device)
    }

    /// Forgets the token and the switch. Removals not yet accepted are kept.
    func forgetPushToken() {
        lastPushRegistration = nil
        setPushDevice(.init(pendingRemovals: value.push?.pendingRemovals))
    }

    /**
     Writes down that the stored token leaves the person in place now, and
     returns the removal to send. Nil for a guest (nothing was registered) or
     when there is no token.
     */
    func beginPushRemoval() -> FounderHQPendingPushRemoval? {
        guard value.identified, var device = value.push, let token = device.token
        else { return nil }
        let removal = FounderHQPendingPushRemoval(
            uuid: uuid.uuid(), token: token, provider: device.provider,
            distinctId: value.distinctId, timestamp: isoString(clock.now())
        )
        device.pendingRemovals = Array(
            ((device.pendingRemovals ?? []) + [removal]).suffix(founderHQMaxPendingPushRemovals)
        )
        setPushDevice(device)
        return removal
    }

    /// Puts the removals at the front of the queue, on a fresh retry ladder.
    func requeuePushRemovals(_ events: [EventPayload]) {
        value.queue = events + value.queue.filter { !Self.isPushDeviceRemoval($0) }
        for event in events { value.deliverySchedule?.removeValue(forKey: event.uuid) }
        pruneQueue()
        persist()
    }

    /**
     Forgets every waiting removal of this device from the person in place
     now: the list entry and the queued copy. The app registers the device for
     that person again, so the removal is out of date.
     */
    func dropPushRemovals(token: String, provider: FounderHQPushProvider) {
        typealias Key = FounderHQProtocolConstants.PushProperty
        let distinctId = value.distinctId
        let before = value.queue.count
        value.queue.removeAll { event in
            guard Self.isPushDeviceRemoval(event), event.distinctId == distinctId,
                  event.properties[Key.token] == .string(token) else { return false }
            let named = event.properties[Key.provider]
            return named == nil || named == .string(provider.rawValue)
        }
        let pending = value.push?.pendingRemovals ?? []
        let kept = pending.filter {
            !$0.matches(token: token, provider: provider, distinctId: distinctId)
        }
        guard kept.count < pending.count || value.queue.count < before else { return }
        pruneDeliverySchedule()
        if var device = value.push {
            device.pendingRemovals = kept
            setPushDevice(device)
        } else {
            persist()
        }
    }

    /**
     Queues a registration, unless it is the same as the last one this process
     queued: same person, same token, same values. One registration moves
     "last seen", a second identical one changes nothing. Returns whether it
     was queued.
     */
    @discardableResult
    func enqueuePushRegistration(_ event: EventPayload, registration: JSONObject) -> Bool {
        let signature = PushRegistrationSignature(
            uuid: event.uuid, distinctId: event.distinctId, registration: registration
        )
        if let last = lastPushRegistration, last.distinctId == signature.distinctId,
           last.registration == signature.registration { return false }
        lastPushRegistration = signature
        enqueue(event)
        return true
    }

    /// A removal leaves the list when ingest answers anything but "retry".
    private func settlePushRemovals(_ uuids: Set<String>) {
        guard var device = value.push, let pending = device.pendingRemovals,
              pending.contains(where: { uuids.contains($0.uuid) }) else { return }
        device.pendingRemovals = pending.filter { !uuids.contains($0.uuid) }
        setPushDevice(device)
    }

    func reset() -> PurchaseIdentityTransition {
        let optedOut = value.optedOut
        let enabled = value.purchaseAttributionEnabled ?? false
        let removals = value.queue.filter(Self.isPushDeviceRemoval)
        lastPushRegistration = nil
        // The token stays on the device so the next identify can register it.
        // The switch does not: it belonged to the person who signs out.
        var push = value.push
        push?.enabled = nil
        if push?.isEmpty == true { push = nil }
        let now = clock.now()
        let id = uuid.uuid()
        value = PersistedState(
            anonymousId: id,
            distinctId: id,
            identified: false,
            purchaseAttributionToken: id,
            purchaseAttributionEnabled: enabled,
            sessionId: uuid.uuidV7(at: now),
            sessionStartedAt: now,
            lastActivityAt: now,
            registered: [:],
            pendingSet: [:],
            pendingSetOnce: [:],
            optedOut: optedOut,
            queue: removals,
            account: nil,
            deliveryAttempts: nil,
            push: push
        )
        persist()
        return .init(token: id, enabled: enabled)
    }

    func enablePurchaseAttribution() -> String {
        let token = value.purchaseAttributionToken ?? value.anonymousId
        value.purchaseAttributionToken = token
        value.purchaseAttributionEnabled = true
        persist()
        return token
    }

    func enqueue(_ event: EventPayload) {
        guard let event = eventForQueue(event) else { return }
        value.queue.append(event)
        pruneQueue()
        persist()
    }
    func enqueueInBackground(_ event: EventPayload) {
        guard let event = eventForQueue(event) else { return }
        value.queue.append(event)
        pruneQueue()
        guard let data = try? JSONEncoder().encode(value) else { return }
        writer.persistInBackground(data)
    }
    /// SDK-built events and purchase controls bypass hook validation.
    private func eventForQueue(_ event: EventPayload) -> EventPayload? {
        guard let beforeSend,
              event.event != "$mobile_purchase_prepared",
              event.event != "$mobile_purchase_claim",
              event.event != FounderHQProtocolConstants.pushDeviceRegisteredEvent,
              event.event != FounderHQProtocolConstants.pushDeviceRemovedEvent
        else { return event }
        do {
            guard let result = try beforeSend(event) else { return nil }
            let name = result.event.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == event.event || isAllowedEvent(name),
                  let distinctId = normalizeDistinctId(result.distinctId),
                  isEventUUID(result.uuid),
                  let instant = parseEventTimestamp(result.timestamp),
                  (try? JSONEncoder().encode(result.properties)) != nil else { return nil }
            // Ingest takes UTC timestamps only: an offset one is the same
            // instant, rewritten rather than lost there. A UTC one keeps its
            // own precision.
            let timestamp = result.timestamp.hasSuffix("Z") ? result.timestamp : isoString(instant)
            // Ingest trims a window id and refuses the whole event for an
            // empty one or one past 200 UTF-16 units; the id goes instead.
            let windowId = result.windowId
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { !$0.isEmpty && $0.utf16.count <= 200 ? $0 : nil }
            // The typed envelope and options expose only known keys, a JSON
            // object for properties, and a boolean for process_person_profile.
            return EventPayload(
                uuid: result.uuid, event: name, distinctId: distinctId,
                timestamp: timestamp, properties: result.properties,
                sessionId: result.sessionId.flatMap { isUUIDv7($0) ? $0 : nil },
                windowId: windowId,
                options: .init(processPersonProfile: result.options.processPersonProfile)
            )
        } catch {
            return nil
        }
    }

    func purchasePreparationIdentity() -> CaptureIdentity {
        let token = value.purchaseAttributionToken ?? value.anonymousId
        value.purchaseAttributionToken = token
        value.purchaseAttributionEnabled = true
        _ = rotateSessionIfNeeded()
        value.lastActivityAt = clock.now()
        return identity
    }
    func markPreparedAcknowledgement(
        token: String,
        acknowledged: Bool
    ) {
        for index in value.queue.indices where
            value.queue[index].event == "$mobile_purchase_prepared" &&
            value.queue[index].properties["purchase_context_token"] == .string(token)
        {
            value.queue[index].properties["prepared_acknowledgement"] = .string(
                acknowledged ? "ACKNOWLEDGED" : "UNACKNOWLEDGED"
            )
        }
        persist()
    }
    /**
     The oldest events that are allowed out right now. An event still serving
     a rung of the retry ladder is skipped, not counted as an attempt, and a
     newer event behind it goes in its place.
     */
    func peek(limit: Int, respectRetryLadder: Bool = true) -> [EventPayload] {
        pruneQueue()
        persist()
        guard respectRetryLadder else {
            return Array(value.queue.prefix(limit))
        }
        let now = clock.now()
        let schedule = value.deliverySchedule ?? [:]
        return Array(
            value.queue
                .filter { Self.isEligible(schedule[$0.uuid], now: now) }
                .prefix(limit)
        )
    }

    private static func isEligible(_ entry: DeliverySchedule?, now: Date) -> Bool {
        guard let entry else { return true }
        if entry.awaitingLaunch == true { return false }
        guard let nextEligibleAt = entry.nextEligibleAt else { return true }
        return now >= nextEligibleAt
    }

    /**
     Puts a restored ladder back to work. A timed rung keeps its deadline, so
     a five minute wait that started before the app was killed still has to
     finish. The final rung is the one this releases: it waits for a launch
     rather than for a clock, and this is that launch.
     */
    private static func scheduleForNewProcess(
        schedule: [String: DeliverySchedule]?,
        legacyAttempts: [String: Int]?,
        queue: [EventPayload]
    ) -> [String: DeliverySchedule]? {
        var restored = schedule ?? [:]
        // A state file from before the ladder carries a bare attempt count and
        // no deadline, so those events go out on the next flush.
        for (uuid, attempts) in legacyAttempts ?? [:] where restored[uuid] == nil {
            restored[uuid] = DeliverySchedule(
                attempts: attempts,
                nextEligibleAt: nil,
                awaitingLaunch: false
            )
        }
        let queued = Set(queue.map(\.uuid))
        restored = restored.filter { queued.contains($0.key) }
        for (uuid, entry) in restored where entry.awaitingLaunch == true {
            restored[uuid] = DeliverySchedule(
                attempts: entry.attempts,
                nextEligibleAt: nil,
                awaitingLaunch: false
            )
        }
        return restored.isEmpty ? nil : restored
    }
    func remove(uuids: Set<String>) {
        settlePushRemovals(uuids)
        value.queue.removeAll { uuids.contains($0.uuid) }
        pruneDeliverySchedule()
        persist()
    }

    func remove(eventsNamed names: Set<String>) {
        guard !names.isEmpty else { return }
        value.queue.removeAll { names.contains($0.event) }
        pruneDeliverySchedule()
        persist()
    }

    /**
     Charges one delivery attempt to every named event, moves each one on to
     its next rung of the retry ladder, and removes the ones that have run off
     the end of it. Returns the removed uuids so the caller can report them.

     The ladder itself is `founderHQRetryLadder`, cut to `maxRetries` rungs
     from the front. The counter and the deadline live beside the queue rather
     than inside the event, because an event carries only what the ingest API
     is allowed to see.
     */
    func countFailedAttempt(uuids: [String]) -> [String] {
        guard !uuids.isEmpty else { return [] }
        let rungs = Array(retryLadder.prefix(maxRetries))
        let now = clock.now()
        var schedule = value.deliverySchedule ?? [:]
        var dropped: [String] = []
        for uuid in uuids {
            let spent = (schedule[uuid]?.attempts ?? 0) + 1
            guard spent <= rungs.count else {
                dropped.append(uuid)
                schedule.removeValue(forKey: uuid)
                continue
            }
            schedule[uuid] = DeliverySchedule(
                attempts: spent,
                // A nil rung is the last one: it waits for the next launch, so
                // it carries no deadline a flush in this process could reach.
                nextEligibleAt: rungs[spent - 1].map(now.addingTimeInterval),
                awaitingLaunch: rungs[spent - 1] == nil
            )
        }
        value.deliverySchedule = schedule.isEmpty ? nil : schedule
        if !dropped.isEmpty {
            let exhausted = Set(dropped)
            value.queue.removeAll { exhausted.contains($0.uuid) }
            if let last = lastPushRegistration, exhausted.contains(last.uuid) {
                lastPushRegistration = nil
            }
        }
        persist()
        return dropped
    }

    func retryIdentify(_ event: EventPayload, directiveId: String?) {
        let anonymousId = directiveId?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? uuid.uuid()
        value.anonymousId = anonymousId
        var properties = event.properties
        properties["$anon_distinct_id"] = .string(anonymousId)
        properties["$device_id"] = .string(anonymousId)
        let retry = EventPayload(
            uuid: uuid.uuid(),
            event: event.event,
            distinctId: event.distinctId,
            timestamp: isoString(clock.now()),
            properties: properties,
            sessionId: event.sessionId,
            windowId: event.windowId,
            options: event.options
        )
        if let retry = eventForQueue(retry) { value.queue.insert(retry, at: 0) }
        persist()
    }

    func persistedData() -> Data? { try? JSONEncoder().encode(value) }

    private func rotateSessionIfNeeded() -> Bool {
        let now = clock.now()
        if now.timeIntervalSince(value.lastActivityAt) >= 30 * 60 ||
            now.timeIntervalSince(value.sessionStartedAt) >= 24 * 60 * 60 {
            value.sessionId = uuid.uuidV7(at: now)
            value.sessionStartedAt = now
            value.lastActivityAt = now
            return true
        }
        return false
    }

    private func applyAccount(_ account: FounderHQAccountContext) -> JSONObject? {
        guard let key = normalizeAccountKey(account.key) else { return nil }
        let contextToken = account.contextToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let spanId = value.account?.key == key ? value.account!.spanId : uuid.uuid()
        value.account = AccountState(
            key: key,
            properties: account.properties,
            contextToken: contextToken,
            spanId: spanId
        )
        return account.properties
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writer.persist(data)
    }

    private func pruneQueue() {
        let before = value.queue.count
        let registrationWaits = lastPushRegistration.map { last in
            value.queue.contains { $0.uuid == last.uuid }
        } ?? false
        value.queue = pruneEventQueue(
            value.queue,
            now: clock.now(),
            maxQueueSize: maxQueueSize,
            eventTTL: eventTTL
        )
        if value.queue.count < before {
            founderHQDebugLog(debug) {
                "dropped \(before - value.queue.count) event(s) over the queue size or age cap"
            }
            // A registration cut from the queue never reached the server.
            if registrationWaits, let last = lastPushRegistration,
               !value.queue.contains(where: { $0.uuid == last.uuid }) {
                lastPushRegistration = nil
            }
        }
        pruneDeliverySchedule()
    }

    /** Forgets the ladder position of events that already left the queue. */
    private func pruneDeliverySchedule() {
        guard let schedule = value.deliverySchedule, !schedule.isEmpty else { return }
        let queued = Set(value.queue.map(\.uuid))
        let kept = schedule.filter { queued.contains($0.key) }
        value.deliverySchedule = kept.isEmpty ? nil : kept
    }
}

private final class FounderHQStateWriter: @unchecked Sendable {
    private let storage: any FounderHQStorage
    private let key: String
    private let lock = NSLock()
    private var writing = false
    private var pending: Data?

    init(storage: any FounderHQStorage, key: String) {
        self.storage = storage
        self.key = key
    }

    func persist(_ data: Data) {
        guard reserve(data) else { return }
        drain(startingWith: data)
    }

    func persistInBackground(_ data: Data) {
        guard reserve(data) else { return }
        DispatchQueue.global().async { [self] in
            drain(startingWith: data)
        }
    }

    private func reserve(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if writing {
            pending = data
            return false
        }
        writing = true
        return true
    }

    private func drain(startingWith data: Data) {
        var next = data
        while true {
            storage.set(next, forKey: key)
            lock.lock()
            if let pending {
                next = pending
                self.pending = nil
                lock.unlock()
            } else {
                writing = false
                lock.unlock()
                return
            }
        }
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object(JSONObject), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode(JSONObject.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public typealias JSONObject = [String: JSONValue]

public struct FounderHQSystemClock: FounderHQClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct FounderHQSystemUUIDProvider: FounderHQUUIDProvider {
    public init() {}
    public func uuid() -> String { UUID().uuidString.lowercased() }

    public func uuidV7(at date: Date) -> String {
        var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        var milliseconds = UInt64(max(0, floor(date.timeIntervalSince1970 * 1_000)))
        for index in stride(from: 5, through: 0, by: -1) {
            bytes[index] = UInt8(milliseconds & 0xff)
            milliseconds >>= 8
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}

public final class FounderHQUserDefaultsStorage: FounderHQStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
}

public struct FounderHQURLSessionTransport: FounderHQTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> FounderHQTransportResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        return .init(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct FounderHQSystemPlatformFactsProvider: FounderHQPlatformFactsProvider {
    public init() {}
    public func properties() -> JSONObject {
        var output: JSONObject = [
            "$locale": .string(Locale.current.identifier),
            "$timezone": .string(TimeZone.current.identifier),
        ]
        if let info = Bundle.main.infoDictionary {
            output["$app_name"] = .string((info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "")
            output["$app_namespace"] = .string(Bundle.main.bundleIdentifier ?? "")
            output["$app_version"] = .string(info["CFBundleShortVersionString"] as? String ?? "")
            output["$app_build"] = .string(info["CFBundleVersion"] as? String ?? "")
        }
        #if canImport(UIKit)
        let device = UIDevice.current
        let screen = UIScreen.main
        let width = screen.bounds.width * screen.scale
        let height = screen.bounds.height * screen.scale
        output["$device_manufacturer"] = .string("Apple")
        output["$device_name"] = .string(device.name)
        output["$device_model"] = .string(device.model)
        // Canonical vocabulary shared with every FounderHQ SDK and the server:
        // "mobile" | "tablet" | "desktop" | "other" (apps/web/src/lib/event-context.ts).
        // Versions up to 1.0.0 sent "Mobile" / "Tablet"; the server respells those.
        // A TV, a car or a headset is a real device that is none of the three,
        // so it says "other" rather than reporting itself as a phone.
        let idiom = device.userInterfaceIdiom
        let deviceType: String
        switch idiom {
        case .phone: deviceType = "mobile"
        case .pad: deviceType = "tablet"
        case .mac: deviceType = "desktop"
        default: deviceType = "other"
        }
        output["$device_type"] = .string(deviceType)
        output["$os"] = .string(device.systemName)
        output["$os_version"] = .string(device.systemVersion)
        output["$screen_width"] = .number(width)
        output["$screen_height"] = .number(height)
        output["$viewport_width"] = .number(width)
        output["$viewport_height"] = .number(height)
        #endif
        return output.filter { _, value in
            if case let .string(text) = value { return !text.isEmpty }
            return true
        }
    }
}

public struct FounderHQDefaultScreenCaptureInstaller: FounderHQScreenCaptureInstalling {
    public init() {}
    public func install(client: FounderHQEvents) {
        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated { FounderHQScreenCapture.install(client: client) }
        } else {
            DispatchQueue.main.async { FounderHQScreenCapture.install(client: client) }
        }
        #endif
    }
}

private typealias EventPayload = FounderHQEvent

public struct FounderHQEvent: Codable, Sendable {
    public var uuid: String
    public var event: String
    public var distinctId: String
    public var timestamp: String
    public var properties: JSONObject
    public var sessionId: String?
    public var windowId: String? = nil
    public var options: FounderHQEventOptions
    enum CodingKeys: String, CodingKey {
        case uuid, event, timestamp, properties, options
        case distinctId = "distinct_id"
        case sessionId = "session_id"
        case windowId = "window_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        event = try values.decode(String.self, forKey: .event)
        distinctId = try values.decode(String.self, forKey: .distinctId)
        timestamp = try values.decode(String.self, forKey: .timestamp)
        properties = try values.decode(JSONObject.self, forKey: .properties)
        sessionId = try? values.decode(String.self, forKey: .sessionId)
        windowId = try? values.decode(String.self, forKey: .windowId)
        options = try values.decode(FounderHQEventOptions.self, forKey: .options)
    }

    init(uuid: String, event: String, distinctId: String, timestamp: String,
         properties: JSONObject, sessionId: String?, windowId: String? = nil,
         options: FounderHQEventOptions) {
        self.uuid = uuid
        self.event = event
        self.distinctId = distinctId
        self.timestamp = timestamp
        self.properties = properties
        self.sessionId = sessionId
        self.windowId = windowId
        self.options = options
    }
}

public struct FounderHQEventOptions: Codable, Sendable {
    public var processPersonProfile: Bool
    enum CodingKeys: String, CodingKey {
        case processPersonProfile = "process_person_profile"
    }
}

private struct EventEnvelope: Codable {
    let sentAt: String
    let batch: [EventPayload]
    enum CodingKeys: String, CodingKey { case sentAt = "sent_at", batch }
}
private struct EventAck: Codable { let results: [String: EventResult]; let directives: [EventDirective]? }
private struct EventResult: Codable { let result: String; let details: String? }
private struct EventDirective: Codable {
    let type: String
    let distinctId: String?
    enum CodingKeys: String, CodingKey { case type; case distinctId = "distinct_id" }
}
private struct PersistedState: Codable {
    var anonymousId: String
    var distinctId: String
    var identified: Bool
    var purchaseAttributionToken: String?
    var purchaseAttributionEnabled: Bool?
    var sessionId: String
    var sessionStartedAt: Date
    var lastActivityAt: Date
    var registered: JSONObject
    var pendingSet: JSONObject
    var pendingSetOnce: JSONObject
    var optedOut: Bool
    var queue: [EventPayload]
    var account: AccountState?
    /**
     Plain attempt counts per queued event uuid, written by SDK versions from
     before the retry ladder. The SDK still decodes them, migrates them into
     `deliverySchedule` on the next launch, and then writes null here.
     */
    var deliveryAttempts: [String: Int]?
    /**
     Where each queued event stands on the retry ladder: the attempts it has
     spent and the moment it may go out again. It sits outside the queue so
     the wire payload stays exactly what the ingest API defines, and it is
     optional so a state file written before this field still decodes.
     */
    var deliverySchedule: [String: DeliverySchedule]?
    /// Absent until the app registers a push token or sets its push switch.
    var push: FounderHQPushDeviceState?
}

extension PersistedState {
    /**
     The same as the synthesized decoder, except for `push`: a push state this
     build cannot read is dropped alone. The identity and the queue must not
     go with it.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        anonymousId = try values.decode(String.self, forKey: .anonymousId)
        distinctId = try values.decode(String.self, forKey: .distinctId)
        identified = try values.decode(Bool.self, forKey: .identified)
        purchaseAttributionToken = try values.decodeIfPresent(
            String.self, forKey: .purchaseAttributionToken
        )
        purchaseAttributionEnabled = try values.decodeIfPresent(
            Bool.self, forKey: .purchaseAttributionEnabled
        )
        sessionId = try values.decode(String.self, forKey: .sessionId)
        sessionStartedAt = try values.decode(Date.self, forKey: .sessionStartedAt)
        lastActivityAt = try values.decode(Date.self, forKey: .lastActivityAt)
        registered = try values.decode(JSONObject.self, forKey: .registered)
        pendingSet = try values.decode(JSONObject.self, forKey: .pendingSet)
        pendingSetOnce = try values.decode(JSONObject.self, forKey: .pendingSetOnce)
        optedOut = try values.decode(Bool.self, forKey: .optedOut)
        queue = try values.decode([EventPayload].self, forKey: .queue)
        account = try values.decodeIfPresent(AccountState.self, forKey: .account)
        deliveryAttempts = try values.decodeIfPresent([String: Int].self, forKey: .deliveryAttempts)
        deliverySchedule = try values.decodeIfPresent(
            [String: DeliverySchedule].self, forKey: .deliverySchedule
        )
        let stored = (try? values.decodeIfPresent(FounderHQPushDeviceState.self, forKey: .push))
            ?? nil
        push = stored?.isEmpty == true ? nil : stored
    }
}

/** One queued event's place on the retry ladder. */
private struct DeliverySchedule: Codable {
    /// Delivery attempts already spent and failed.
    var attempts: Int
    /**
     The earliest moment a flush may send this event again. Nil means the
     event is eligible now.
     */
    var nextEligibleAt: Date?
    /**
     The event is parked on the last rung, which no clock releases. Only a new
     process clears it, which is what makes that rung fire exactly once per
     app launch.
     */
    var awaitingLaunch: Bool?
}
private struct AccountState: Codable, Sendable {
    let key: String
    var properties: JSONObject
    let contextToken: String?
    let spanId: String
}
/// What makes two registrations the same. `uuid` names the queued event.
private struct PushRegistrationSignature {
    let uuid: String
    let distinctId: String
    let registration: JSONObject
}
private struct CaptureIdentity {
    let anonymousId: String
    let distinctId: String
    let identified: Bool
    let purchaseAttributionToken: String
    let purchaseAttributionEnabled: Bool
    let sessionId: String
    let account: AccountState?
}
private struct SessionIdentityResult { let identity: CaptureIdentity; let rotated: Bool }
private struct IdentityTransition {
    let anonymousId: String
    let set: JSONObject
    let setOnce: JSONObject
    let purchaseAttributionToken: String
    let purchaseAttributionEnabled: Bool
    let groupSet: JSONObject?
}
private struct PurchaseIdentityTransition { let token: String; let enabled: Bool }
private struct PersonMutation { let set: JSONObject; let setOnce: JSONObject }

private enum FounderHQPurchaseError: Error {
    case invalidPurchaseContext
    case unverifiedTransaction
    case missingProviderReference
}

private struct FounderHQReflectedRevenueCatPurchase {
    let store: String
    let transactionId: String?
    let subscriptionId: String?
    let purchaseToken: String?
    let productId: String?
    let purchasedAt: String?
}

private func reflectedRevenueCatPurchase(
    _ value: Any
) -> FounderHQReflectedRevenueCatPurchase? {
    let transactionId = reflectedString(
        value,
        names: ["transactionIdentifier", "transactionId", "identifier"]
    )
    let subscriptionId = reflectedString(
        value,
        names: ["originalTransactionIdentifier", "originalTransactionId"]
    )
    let purchaseToken = reflectedString(value, names: ["purchaseToken"])
    guard transactionId != nil || subscriptionId != nil || purchaseToken != nil else {
        return nil
    }
    let storeField = reflectedString(value, names: ["store"])?.lowercased()
    let store = storeField?.contains("play") == true || purchaseToken != nil
        ? "GOOGLE_PLAY"
        : "APP_STORE"
    let purchasedAt: String?
    if let date = reflectedField(value, names: ["purchaseDate"]) as? Date {
        purchasedAt = isoString(date)
    } else {
        purchasedAt = reflectedString(value, names: ["purchaseDate"])
    }
    return .init(
        store: store,
        transactionId: transactionId,
        subscriptionId: subscriptionId ?? purchaseToken,
        purchaseToken: purchaseToken,
        productId: reflectedString(
            value,
            names: ["productIdentifier", "productId"]
        ),
        purchasedAt: purchasedAt
    )
}

private func reflectedString(_ value: Any, names: [String]) -> String? {
    guard let field = reflectedField(value, names: names) else { return nil }
    if let string = field as? String { return string.isEmpty ? nil : string }
    if let convertible = field as? CustomStringConvertible {
        let string = convertible.description
        return string.isEmpty ? nil : string
    }
    return nil
}

private func reflectedField(_ value: Any, names: [String]) -> Any? {
    let unwrapped = unwrapReflectedOptional(value)
    let mirror = Mirror(reflecting: unwrapped)
    for child in mirror.children where names.contains(child.label ?? "") {
        return unwrapReflectedOptional(child.value)
    }
    return nil
}

private func unwrapReflectedOptional(_ value: Any) -> Any {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value }
    return mirror.children.first.map { unwrapReflectedOptional($0.value) } ?? value
}

private struct FounderHQPurchasePreparationResult: Sendable {
    let prepared: FounderHQPreparedPurchase
    let acknowledged: Bool
}

private enum FounderHQPurchasePreparationOutcome: @unchecked Sendable {
    case completed(FounderHQPurchasePreparationResult)
    case failed(any Error)
}

private final class FounderHQOneShotPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FounderHQPurchasePreparationOutcome, Never>?

    init(
        _ continuation: CheckedContinuation<FounderHQPurchasePreparationOutcome, Never>
    ) {
        self.continuation = continuation
    }

    func resume(_ value: FounderHQPurchasePreparationOutcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/**
 The last session id the SDK captured with, readable without awaiting the state
 actor. Only the tracing header needs this: it runs inside the app's own
 URLSession call and cannot suspend.
 */
final class FounderHQSessionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

/**
 The element-capture switches as of the last config the SDK applied, readable
 without an `await`. The UIKit hooks are synchronous and run on the main
 thread, so they cannot suspend on the capture-policy actor to ask.
 */
final class FounderHQInteractionCaptureSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var elementsValue = false
    private var rageClicksValue = false

    var elements: Bool {
        lock.lock()
        defer { lock.unlock() }
        return elementsValue
    }

    var rageClicks: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rageClicksValue
    }

    func set(elements: Bool, rageClicks: Bool) {
        lock.lock()
        elementsValue = elements
        rageClicksValue = rageClicks
        lock.unlock()
    }
}

/** Prints only when the app asked for it through `debug`. */
func founderHQDebugLog(_ enabled: Bool, _ message: () -> String) {
    guard enabled else { return }
    NSLog("[FounderHQEvents] %@", message())
}

private final class FounderHQLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func getOrSet(_ candidate: @autoclosure () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let created = candidate()
        value = created
        return created
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func setIfEmpty(_ value: Value) {
        lock.lock()
        if self.value == nil { self.value = value }
        lock.unlock()
    }
}

private func controlAccountProperties(_ account: AccountState?) -> JSONObject {
    guard let account else { return [:] }
    var properties: JSONObject = [
        "$groups": .object(["account": .string(account.key)]),
        "$account_span_id": .string(account.spanId),
    ]
    if let contextToken = account.contextToken {
        properties["$account_context_token"] = .string(contextToken)
    }
    return properties
}

private func wirePurchaseSource(_ source: FounderHQPurchaseSource) -> String {
    switch source {
    case .revenueCat: return "REVENUECAT"
    case .storeKit: return "STOREKIT"
    case .playBilling: return "PLAY_BILLING"
    }
}

private func shouldProcessPersonProfile(
    _ mode: FounderHQPersonProfiles,
    identified: Bool
) -> Bool {
    mode == .always || (mode == .identifiedOnly && identified)
}
// One source of truth: generated from @founderhq/events-core.
private let allowedReservedEvents: Set<String> = Set(
    FounderHQProtocolConstants.reservedEventNames
)
private let campaignKeys: Set<String> = Set(
    FounderHQProtocolConstants.campaignProperties
)

private func isUUIDv7(_ value: String) -> Bool {
    let text = value.lowercased()
    guard isEventUUID(value), text.count == 36,
          text[text.index(text.startIndex, offsetBy: 8)] == "-",
          text[text.index(text.startIndex, offsetBy: 13)] == "-",
          text[text.index(text.startIndex, offsetBy: 18)] == "-",
          text[text.index(text.startIndex, offsetBy: 23)] == "-",
          text[text.index(text.startIndex, offsetBy: 14)] == "7",
          "89ab".contains(text[text.index(text.startIndex, offsetBy: 19)])
    else { return false }
    return text.enumerated().allSatisfy { offset, character in
        [8, 13, 18, 23].contains(offset) || character.isHexDigit
    }
}

private func isAllowedEvent(_ name: String) -> Bool {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty && value.count <= 200 && (!value.hasPrefix("$") || allowedReservedEvents.contains(value))
}

private func normalizeAccountKey(_ value: String) -> String? {
    let key = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping
    guard !key.isEmpty, key.lengthOfBytes(using: .utf8) <= 200 else { return nil }
    return key
}

func json(_ input: [String: Any]) -> JSONObject { input.mapValues(jsonValue) }
private func jsonValue(_ value: Any) -> JSONValue {
    switch value {
    case let value as JSONValue: return value
    case let value as String: return .string(value)
    case let value as NSNumber:
        return CFGetTypeID(value) == CFBooleanGetTypeID()
            ? .bool(value.boolValue)
            : .number(value.doubleValue)
    case let value as Double: return .number(value)
    case let value as [String: Any]: return .object(json(value))
    case let value as [Any]: return .array(value.map(jsonValue))
    default: return .null
    }
}

private func standaloneProperties(_ input: JSONObject) -> JSONObject {
    var output = input
    ["email", "phone", "externalId", "external_id", "distinct_id"].forEach {
        output.removeValue(forKey: $0)
    }
    return output
}

private func campaignProperties(_ url: URL) -> [String: Any] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
        campaignKeys.contains(item.name) && item.value != nil ? (item.name, item.value!) : nil
    })
}

private func isoString(_ date: Date) -> String { ISO8601DateFormatter.fhq.string(from: date) }

private func normalizeDistinctId(_ value: String) -> String? {
    let distinctId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !distinctId.isEmpty, distinctId.count <= 400,
          !FounderHQProtocolConstants.illegalDistinctIds.contains(distinctId.lowercased())
    else { return nil }
    return distinctId
}

/**
 The wait before each retry, in seconds, with `nil` for the final rung: that
 one waits for the next process launch rather than for a clock. See
 `FounderHQEventsConfiguration.maxRetries` for why the ladder looks like this.
 */
let founderHQRetryLadder: [TimeInterval?] = [30, 30, 120, 300, nil]

/**
 Cuts the queue to its age and size limits. A device removal is an instruction
 and not analytics: it has no age limit (it keeps the time of the sign-out, and
 the list of pending removals holds at most 10), and when the queue is over its
 size, the other events are cut first, oldest first.
 */
private func pruneEventQueue(
    _ queue: [EventPayload],
    now: Date,
    maxQueueSize: Int,
    eventTTL: TimeInterval
) -> [EventPayload] {
    let cutoff = now.addingTimeInterval(-max(0, eventTTL))
    func isRemoval(_ event: EventPayload) -> Bool {
        event.event == FounderHQProtocolConstants.pushDeviceRemovedEvent
    }
    var kept = queue.filter {
        if isRemoval($0) { return true }
        guard let createdAt = parseEventTimestamp($0.timestamp) else {
            return false
        }
        return createdAt >= cutoff
    }
    let limit = max(1, maxQueueSize)
    var excess = kept.count - limit
    guard excess > 0 else { return kept }
    kept = kept.filter { event in
        guard excess > 0, !isRemoval(event) else { return true }
        excess -= 1
        return false
    }
    // Only removals are left over the limit: the newest stay.
    return Array(kept.suffix(limit))
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension ISO8601DateFormatter {
    static let fhq: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
