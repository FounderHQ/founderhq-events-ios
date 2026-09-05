#if canImport(SwiftUI)
import SwiftUI

public extension View {
    func founderHQScreen(
        _ name: String,
        client: FounderHQEvents,
        properties: [String: Any] = [:]
    ) -> some View {
        onAppear { client.screen(name, properties: properties) }
    }
}
#endif
