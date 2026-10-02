import SwiftUI

@main
struct MacNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app: AppState
    private let input = InputManager()

    init() {
        Theme.registerFonts()
        // Artwork cache lives in the data folder too.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20,
                                   directory: Paths.cache.appendingPathComponent("http"))
        _app = State(initialValue: AppState())
    }

    var body: some Scene {
        WindowGroup("MacNative") {
            RootView()
                .environment(app)
                .task {
                    input.handler = { [app] action in app.handle(action) }
                    input.onControllersChanged = { [app] name in app.controllerName = name }
                    input.start()
                    await app.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { app.showAddGame = true }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.route = .settings }.keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` starts us as a background process; make sure we get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
