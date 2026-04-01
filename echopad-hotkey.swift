/**
 echopad-hotkey — Global keyboard shortcut to toggle echopad recording.
 Registers Ctrl+Shift+E as a system-wide hotkey via CGEvent tap.
 Runs echopad-toggle when pressed, works in ALL apps including Brave.

 Requires Accessibility permission:
   System Settings → Privacy & Security → Accessibility
 */

import Cocoa
import Carbon.HIToolbox

let toggleScript = (ProcessInfo.processInfo.environment["HOME"] ?? "/Users/lukaszpiera")
    + "/Projects/echopad/echopad-toggle"

let hotKeyCode: CGKeyCode = 14  // E key

var tapRef: CFMachPort?

func handleHotKey() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", toggleScript]
    task.environment = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/Users/lukaszpiera"
    ]
    do {
        try task.run()
    } catch {
        fputs("echopad-hotkey: failed to run toggle script: \(error)\n", stderr)
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ -> Unmanaged<CGEvent>? in
    if type == .keyDown {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if keyCode == hotKeyCode
            && flags.contains(.maskControl)
            && flags.contains(.maskShift)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate) {
            handleHotKey()
            return nil  // consume the event
        }
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tapRef {
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}

let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
) else {
    fputs("echopad-hotkey: Failed to create event tap.\n", stderr)
    fputs("Grant Accessibility permission: System Settings → Privacy & Security → Accessibility\n", stderr)
    exit(1)
}

tapRef = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

fputs("echopad-hotkey: listening for Ctrl+Shift+E (PID \(ProcessInfo.processInfo.processIdentifier))\n", stderr)

CFRunLoopRun()
