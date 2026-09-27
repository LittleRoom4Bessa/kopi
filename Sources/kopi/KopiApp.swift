import SwiftUI

@main
struct KopiApp: App {
    @State private var state = AppState()

    var body: some Scene {
        // Primary surface: menu bar popover (design D7).
        MenuBarExtra("kopi", systemImage: "externaldrive.fill.badge.checkmark") {
            ContentView()
                .environment(state)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)

        // Supplementary singleton window for pro mode; opened on demand via
        // `openWindow(id: "pro")` and never shows at launch.
        Window("kopi pro", id: "pro") {
            ProPanelView()
                .environment(state)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 620, height: 700)
    }
}
