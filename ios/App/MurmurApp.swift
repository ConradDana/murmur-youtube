import SwiftUI

@main
struct MurmurApp: App {
    @State private var controller = SessionController.shared
    /// Set when the keyboard bounced the user here, so the screen can say how to get back.
    @State private var openedFromKeyboard = false

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, openedFromKeyboard: $openedFromKeyboard)
                .onOpenURL { url in
                    guard url.scheme == Bridge.urlScheme else { return }
                    openedFromKeyboard = true
                    Task { await controller.startSession() }
                }
        }
    }
}
