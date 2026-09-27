import SwiftUI

@main
struct KopiApp: App {
    @State private var state = AppState()

    var body: some Scene {
        // Single surface: the menu bar popover. Pro mode expands it in place.
        MenuBarExtra("kopi", systemImage: "externaldrive.fill.badge.checkmark") {
            ContentView()
                .environment(state)
        }
        .menuBarExtraStyle(.window)
    }
}
