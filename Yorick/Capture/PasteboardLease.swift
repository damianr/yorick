import AppKit
import CoreGraphics
import os

/// Owns the pasteboard for the duration of a dictation paste — the LEASE:
/// snapshot the user's clipboard (every item, every representation type),
/// put the transcript up, synthesize ⌘V, and put the user's clipboard back
/// the moment it's safe. Three ways a lease ends; first one wins:
///
///   1. The USER presses ⌘V themselves. An event tap — armed only while a
///      lease is live — restores the clipboard SYNCHRONOUSLY before their
///      keystroke is delivered, so they paste their own content, never a
///      leftover transcript (field-reported failure this exists to kill).
///   2. The frontmost app changes. Switching away means the paste landed;
///      restore immediately so the next app sees the real clipboard.
///   3. A 2s wall clock — the cushion that lets a slow app process the ⌘V
///      before the transcript vanishes out from under it.
///
/// Every restore is token-guarded: if the user copied something NEW during
/// the lease, the lease expires without touching the pasteboard. And the
/// transcript is written with the nspasteboard.org transient + concealed
/// markers, so well-behaved clipboard managers don't record a history entry
/// for every dictation.
@MainActor
enum PasteboardLease {
    private static let log = Logger(subsystem: "com.heyyorick.Yorick", category: "pasteboard")

    private static let tokenType = NSPasteboard.PasteboardType("com.heyyorick.Yorick.dictation-token")
    /// nspasteboard.org conventions — clipboard managers that honor them
    /// (Maccy, Paste, Raycast, Alfred) skip transient/concealed content.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let restoreDelay: TimeInterval = 2.0
    /// Stamped on our synthesized key events so the user-paste tap can tell
    /// them apart from a real keystroke. ("YORI")
    nonisolated static let syntheticEventTag: Int64 = 0x594F_5249

    private static var snapshot: Snapshot?
    private static var token: String?
    private static var restoreWork: DispatchWorkItem?
    private static var tap: CFMachPort?
    private static var tapSource: CFRunLoopSource?
    private static var workspaceObserver: NSObjectProtocol?

    // MARK: - Snapshot (full fidelity, not string-only)

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(from pasteboard: NSPasteboard, excluding excludedTypes: Set<NSPasteboard.PasteboardType>) {
            items = (pasteboard.pasteboardItems ?? []).compactMap { item in
                var savedItem: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types where !excludedTypes.contains(type) {
                    if let data = item.data(forType: type) {
                        savedItem[type] = data
                    }
                }
                return savedItem.isEmpty ? nil : savedItem
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let pasteboardItems = items.map { savedItem in
                let item = NSPasteboardItem()
                for (type, data) in savedItem {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(pasteboardItems)
        }
    }

    // MARK: - Lease lifecycle

    /// Take the pasteboard: snapshot what's there, put the transcript up.
    static func begin(_ text: String) {
        let pasteboard = NSPasteboard.general
        let currentToken = pasteboard.string(forType: tokenType)

        // If Yorick already owns the pasteboard from a dictation moments
        // ago, keep the ORIGINAL snapshot so rapid follow-up dictations
        // still restore the user's real clipboard. If the user changed the
        // clipboard since, start a new lease from that current content.
        // Only our token is excluded from the snapshot — a user's own
        // transient/concealed markers (a copied password) restore intact.
        if snapshot == nil || currentToken != token {
            snapshot = Snapshot(from: pasteboard, excluding: [tokenType])
        }
        restoreWork?.cancel()
        restoreWork = nil
        disarmEarlyTriggers()

        let newToken = UUID().uuidString
        token = newToken
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(newToken, forType: tokenType)
        pasteboard.setString("", forType: transientType)
        pasteboard.setString("", forType: concealedType)
    }

    /// Synthesize ⌘V at session level, tagged as ours.
    static func postPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// Arm the early-flush triggers and the fallback clock.
    static func scheduleRestore() {
        armEarlyTriggers()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                finish(reason: "lease expired")
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    /// End the lease now (user ⌘V, app switch, app quitting). Safe to call
    /// when no lease is live.
    static func flushEarly(reason: String) {
        guard token != nil else { return }
        finish(reason: reason)
    }

    private static func finish(reason: String) {
        disarmEarlyTriggers()
        restoreWork?.cancel()
        restoreWork = nil
        guard let owned = token else { return }
        token = nil
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: tokenType) == owned else {
            // The user copied something during the lease — their newer
            // clipboard wins; never overwrite it.
            snapshot = nil
            log.notice("lease ended (\(reason, privacy: .public)) — clipboard changed, left intact")
            return
        }
        snapshot?.restore(to: pasteboard)
        snapshot = nil
        log.notice("clipboard restored (\(reason, privacy: .public))")
    }

    // MARK: - Early-flush triggers

    private static func armEarlyTriggers() {
        disarmEarlyTriggers()
        // Active session tap: allowed for accessibility-trusted processes,
        // which Yorick must already be to dictate at all. Head-inserted so
        // the restore happens BEFORE the user's paste reaches its app. If
        // creation ever fails, the wall clock still bounds the lease.
        // (Keycode 9 is the ANSI V position — a non-ANSI layout's ⌘V may
        // not match, and then simply falls through to the clock.)
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        if let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .keyDown,
                   event.getIntegerValueField(.eventSourceUserData) != PasteboardLease.syntheticEventTag,
                   event.getIntegerValueField(.keyboardEventKeycode) == 9,
                   event.flags.contains(.maskCommand) {
                    // The tap's run-loop source lives on the main loop, so
                    // the callback runs on the main thread.
                    MainActor.assumeIsolated {
                        PasteboardLease.flushEarly(reason: "user ⌘V")
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
            tap = newTap
            tapSource = source
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                flushEarly(reason: "app switched")
            }
        }
    }

    private static func disarmEarlyTriggers() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }
}
