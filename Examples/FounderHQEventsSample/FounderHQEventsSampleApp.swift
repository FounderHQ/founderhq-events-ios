import SwiftUI
import FounderHQEvents

@main
struct FounderHQEventsSampleApp: App {
    private let events = FounderHQEvents(apiKey: "fhq_pk_replace_me")

    var body: some Scene {
        WindowGroup {
            Button("Capture signup") {
                events.capture("signup.completed", properties: ["source": "ios_sample"])
            }
            .founderHQScreen("Events sample", client: events)
            .onOpenURL { events.captureDeepLink($0) }
        }
    }
}
