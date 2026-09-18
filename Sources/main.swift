// DockPin
// Keeps the macOS Dock on the main display (the one holding the menu bar in
// System Settings > Displays > Arrange).
//
// How it works
// 1. An event tap watches mouse movement. On every display except the main one,
//    the cursor is kept a few points above the bottom edge, so the Dock never
//    gets the "cursor pushed against the bottom" signal that makes it jump.
// 2. On launch, on wake and when displays change, it checks where the Dock is.
//    If it is not on the main display, it pushes the cursor against the bottom
//    edge of the main display with synthetic mouse events, which pulls the Dock
//    over. (Restarting the Dock does not help: it comes back where it was.)

import AppKit
import ServiceManagement

// MARK: - Tunables

/// Points kept clear above the bottom edge of guarded displays.
private let edgeBuffer: CGFloat = 4
/// Safety valve so a misdetection can never cause a Dock restart loop.
private let maxAutoResets = 3
private let autoResetWindow: TimeInterval = 600

// MARK: - Log

private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DockPin.log")

/// Appends a timestamped line to ~/Library/Logs/DockPin.log.
func dpLog(_ message: String) {
    NSLog("DockPin: %@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Event tap callback (C function pointer, cannot capture context)

private func dockPinTapCallback(proxy: CGEventTapProxy,
                                type: CGEventType,
                                event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let pin = Unmanaged<DockPin>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        pin.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    pin.clamp(event)
    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class DockPin: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private var pendingEvaluate: DispatchWorkItem?

    private var allBounds: [CGRect] = []
    private var guarded: [CGRect] = []
    private var displayIDs: Set<CGDirectDisplayID> = []
    private var lastDisplayIDs: Set<CGDirectDisplayID> = []
    private var dockAtBottom = true
    private var paused = false
    private var autoResets: [Date] = []
    private var moving = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(displaysChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)

        refreshDisplays()
        ensureTap(prompt: true)
    }

    @objc private func displaysChanged() { scheduleEvaluate(after: 2.0) }
    @objc private func didWake() { scheduleEvaluate(after: 4.0) }

    // MARK: Cursor guard

    /// Called for every mouse move or drag. Keeps the cursor off the bottom
    /// edge of every display that is not the main one.
    fileprivate func clamp(_ event: CGEvent) {
        if paused || guarded.isEmpty { return }
        let p = event.location

        for b in guarded {
            let limit = b.maxY - edgeBuffer
            guard p.x >= b.minX, p.x < b.maxX, p.y > limit, p.y <= b.maxY + 1 else { continue }

            // If another display sits directly below this spot, the edge is a
            // doorway rather than a wall, so leave it alone.
            let below = CGPoint(x: p.x, y: b.maxY + 1)
            if allBounds.contains(where: { $0.contains(below) }) { return }

            let q = CGPoint(x: p.x, y: limit)
            CGWarpMouseCursorPosition(q)
            // Cancels the short event freeze that follows a cursor warp.
            CGAssociateMouseAndMouseCursorPosition(1)
            event.location = q
            if event.getIntegerValueField(.mouseEventDeltaY) > 0 {
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            }
            return
        }
    }

    fileprivate func reenableTap() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func ensureTap(prompt: Bool) {
        if tap != nil { return }

        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if prompt { dpLog("launch, accessibility trusted: \(trusted)") }
        guard trusted else {
            if trustTimer == nil {
                trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.ensureTap(prompt: false)
                }
            }
            return
        }

        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()

        for location in [CGEventTapLocation.cghidEventTap, CGEventTapLocation.cgSessionEventTap] {
            guard let port = CGEvent.tapCreate(tap: location,
                                               place: .headInsertEventTap,
                                               options: .defaultTap,
                                               eventsOfInterest: mask,
                                               callback: dockPinTapCallback,
                                               userInfo: me) else { continue }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            tap = port
            tapSource = source
            break
        }

        dpLog(tap != nil ? "event tap active" : "event tap refused")
        if tap != nil {
            trustTimer?.invalidate()
            trustTimer = nil
            // Posting the synthetic push needs the same permission, so check
            // the Dock once we have it.
            scheduleEvaluate(after: 1.0)
        } else if trustTimer == nil {
            // Trusted but the tap was refused. Usually fixed by a relaunch,
            // keep retrying in the meantime.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.ensureTap(prompt: false)
            }
        }
        updateIcon()
    }

    // MARK: Displays

    private func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetActiveDisplayList(count, &ids, &count) }
        ids = Array(ids.prefix(Int(count)))

        let main = CGMainDisplayID()
        displayIDs = Set(ids)
        allBounds = ids.map { CGDisplayBounds($0) }
        dockAtBottom = DockPin.dockOrientation() == "bottom"
        guarded = dockAtBottom ? ids.filter { $0 != main }.map { CGDisplayBounds($0) } : []
    }

    private static func dockOrientation() -> String {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String) ?? "bottom"
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen whose usable area is shortened at the bottom is the one
    /// showing the Dock. Returns nil when the Dock auto hides (no inset).
    private func displayShowingDock() -> CGDirectDisplayID? {
        for screen in NSScreen.screens where screen.visibleFrame.minY - screen.frame.minY > 1 {
            return DockPin.displayID(of: screen)
        }
        return nil
    }

    private func mainDisplayName() -> String {
        let main = CGMainDisplayID()
        return NSScreen.screens.first { DockPin.displayID(of: $0) == main }?.localizedName ?? "main display"
    }

    // MARK: Dock placement

    private func scheduleEvaluate(after delay: TimeInterval) {
        pendingEvaluate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pendingEvaluate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate() {
        refreshDisplays()
        let setChanged = displayIDs != lastDisplayIDs
        lastDisplayIDs = displayIDs
        updateIcon()

        dpLog("evaluate: main=\(CGMainDisplayID()) dock=\(displayShowingDock().map(String.init) ?? "unknown") paused=\(paused) tap=\(tap != nil) bottom=\(dockAtBottom) displays=\(displayIDs.count)")
        guard !paused, tap != nil, dockAtBottom, displayIDs.count > 1 else { return }

        if let dockDisplay = displayShowingDock() {
            if dockDisplay != CGMainDisplayID() { moveDockToMain(automatic: true) }
        } else if setChanged {
            // Dock auto hides, so its position cannot be read. Only reset when
            // the set of connected displays actually changed.
            moveDockToMain(automatic: true)
        }
    }

    /// Moves the Dock to the main display the same way a person does: push
    /// the cursor against the bottom edge of the main display. Restarting the
    /// Dock does not work, it comes back on whichever display it was last on.
    private func moveDockToMain(automatic: Bool) {
        if moving { return }
        if automatic {
            let now = Date()
            autoResets = autoResets.filter { now.timeIntervalSince($0) < autoResetWindow }
            guard autoResets.count < maxAutoResets else {
                dpLog("too many automatic Dock moves, skipping this one")
                return
            }
            autoResets.append(now)
        }

        let b = CGDisplayBounds(CGMainDisplayID())
        // The push only works on a stretch of edge with no display below it.
        let step = max(1, b.width / 64)
        let candidates = stride(from: b.minX + 20, to: b.maxX - 20, by: step)
        guard let x = candidates.first(where: { x in
            !allBounds.contains { $0.contains(CGPoint(x: x, y: b.maxY + 1)) }
        }) else {
            dpLog("the main display has another display along its whole bottom edge, cannot move the Dock there")
            return
        }

        dpLog("moving Dock: pushing at x=\(Int(x)) on main display bounds \(b)")
        moving = true
        let bottom = b.maxY - 1
        let original = CGEvent(source: nil)?.location
        // Post from a background queue: the event tap runs on the main run loop
        // and must keep up with these events.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ y: CGFloat, _ dy: Int64) {
                guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                      mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventDeltaY, value: dy)
                e.post(tap: .cghidEventTap)
                usleep(10_000)
            }
            CGWarpMouseCursorPosition(CGPoint(x: x, y: bottom - 40))
            CGAssociateMouseAndMouseCursorPosition(1)
            for i in 0..<20 { post(bottom - 40 + CGFloat(i * 2), 2) }
            for _ in 0..<60 { post(bottom, 6) }
            usleep(400_000)
            if let o = original {
                CGWarpMouseCursorPosition(o)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.moving = false
                dpLog("after move: Dock on display \(self.displayShowingDock().map(String.init) ?? "unknown (auto hide)")")
            }
        }
    }

    // MARK: Menu

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockPin") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = "DP"
        }
        button.appearsDisabled = paused || tap == nil
    }

    private func statusLine() -> String {
        if tap == nil { return "Waiting for Accessibility permission" }
        if paused { return "Paused" }
        if !dockAtBottom { return "Idle (Dock is on the side)" }
        if displayIDs.count < 2 { return "Idle (single display)" }
        return "Dock pinned to \(mainDisplayName())"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if tap == nil {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        menu.addItem(item("Move Dock to Main Display Now", #selector(moveNow)))

        let pause = item("Pause", #selector(togglePause))
        pause.state = paused ? .on : .off
        menu.addItem(pause)

        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("About DockPin", #selector(showAbout)))
        menu.addItem(item("Quit DockPin", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func moveNow() { moveDockToMain(automatic: false) }

    @objc private func togglePause() {
        paused.toggle()
        updateIcon()
        if !paused { scheduleEvaluate(after: 0.5) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add DockPin manually in System Settings > General > Login Items & Extensions."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Developed by Nicolas Boada\nTALKK Web & App Studio\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "talkk.com.au",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://talkk.com.au")!]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))

        // Accessory apps are never frontmost, so bring the panel forward.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = DockPin()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
