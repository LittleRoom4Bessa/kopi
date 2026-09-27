import SwiftUI

@main
struct KopiApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("kopi", systemImage: "externaldrive.fill.badge.checkmark") {
            ContentView()
                .environmentObject(state)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}
