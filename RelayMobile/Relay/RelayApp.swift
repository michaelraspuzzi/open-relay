import SwiftUI

@main
struct RelayApp: App {
    @State private var link = MacLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if link.pairing == nil && !link.demo {
                    PairView(link: link)
                } else {
                    RootView(link: link)
                }
            }
            .preferredColorScheme(.dark)
            // The Camera app hands over the pairing code as relay://pair?...
            .onOpenURL { url in _ = link.pair(with: url) }
            .task {
                if ProcessInfo.processInfo.environment["RELAY_DEMO"] != nil { link.startDemo() } else { link.connect() }
            }
            .onChange(of: phase) { _, now in
                if now == .active { link.resume() }
                if now == .background && !link.demo { link.disconnect() }
            }
        }
    }
}
