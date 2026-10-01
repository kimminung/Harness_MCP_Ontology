import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS) || os(visionOS)
        .defaultSize(width: 1280, height: 780)
        #endif
    }
}
