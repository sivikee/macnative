import AppKit
import GameController

/// Launcher navigation actions, shared by controllers and the keyboard.
enum NavAction {
    case up, down, left, right
    case confirm      // A / Cross / Return
    case back         // B / Circle / Escape
    case previousTab  // LB / L1 / Q
    case nextTab      // RB / R1 / E
    case search       // Y / Triangle / ⌘F
    case secondary    // X / Square / F — toggle favorite
    case menu         // Start / Options / ⌘, — settings
}

/// Bridges every controller supported by Apple's GameController framework (Xbox, PlayStation
/// DualShock 4 / DualSense, Switch Pro, MFi, …) and the keyboard to `NavAction`s.
/// Input is ignored while MacNative isn't the active app, so games keep the controller to themselves.
@MainActor
final class InputManager {
    /// Returns whether the action was used; unused keyboard events continue to the focused control.
    var handler: ((NavAction) -> Bool)?
    private(set) var connectedName: String?
    var onControllersChanged: ((String?) -> Void)?

    private var repeatTask: Task<Void, Never>?
    private var heldDirection: NavAction?
    private var keyMonitor: Any?

    func start() {
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.attach(note.object as? GCController) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshName() }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = Self.action(for: event) else { return event }
            return self.fire(action) ? nil : event
        }
    }

    private func attach(_ controller: GCController?) {
        guard let pad = controller?.extendedGamepad else { refreshName(); return }

        func button(_ b: GCControllerButtonInput, _ action: NavAction) {
            b.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                // GameController delivers handlers on the main queue by default.
                MainActor.assumeIsolated { _ = self?.fire(action) }
            }
        }
        button(pad.buttonA, .confirm)
        button(pad.buttonB, .back)
        button(pad.buttonX, .secondary)
        button(pad.buttonY, .search)
        button(pad.leftShoulder, .previousTab)
        button(pad.rightShoulder, .nextTab)
        button(pad.buttonMenu, .menu)

        func directional(_ dpad: GCControllerDirectionPad) {
            dpad.valueChangedHandler = { [weak self] _, x, y in
                let dir: NavAction? =
                    y > 0.5 ? .up : y < -0.5 ? .down : x < -0.5 ? .left : x > 0.5 ? .right : nil
                MainActor.assumeIsolated { self?.hold(dir) }
            }
        }
        directional(pad.dpad)
        directional(pad.leftThumbstick)
        refreshName()
    }

    private func refreshName() {
        connectedName = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.vendorName
        onControllersChanged?(connectedName)
    }

    /// Fires a direction immediately, then repeats while held (like console menus).
    private func hold(_ dir: NavAction?) {
        guard dir != heldDirection else { return }
        heldDirection = dir
        repeatTask?.cancel()
        guard let dir else { return }
        fire(dir)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                self?.fire(dir)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    @discardableResult
    private func fire(_ action: NavAction) -> Bool {
        guard NSApp.isActive else { return false }
        return handler?(action) ?? false
    }

    private static func action(for event: NSEvent) -> NavAction? {
        // Leave typing alone when a text field has focus.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return event.keyCode == 53 ? .back : nil
        }
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, cmd) {
        case (126, _): return .up
        case (125, _): return .down
        case (123, _): return .left
        case (124, _): return .right
        case (36, false), (49, false): return .confirm
        case (53, _): return .back
        case (12, false): return .previousTab   // Q
        case (14, false): return .nextTab       // E
        case (3, true): return .search          // ⌘F
        case (3, false): return .secondary      // F
        default: return nil
        }
    }
}
