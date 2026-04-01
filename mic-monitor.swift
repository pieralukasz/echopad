/**
 mic-monitor — prints MIC_ON / MIC_OFF to stdout when ANY input device
 starts or stops being used by any process.

 Listens on ALL audio input devices via CoreAudio property listeners.
 Zero CPU when idle — callbacks fire only on state change.
 */

import CoreAudio
import Foundation

// MARK: - Helpers

func getAllInputDevices() -> [AudioDeviceID] {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size
    )
    guard status == noErr else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &devices
    )
    guard status == noErr else { return [] }

    // Filter to input devices only
    return devices.filter { hasInputChannels($0) }
}

func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    guard status == noErr, size > 0 else { return false }

    let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    defer { bufferListPtr.deallocate() }
    let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPtr)
    guard getStatus == noErr else { return false }

    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
    for buf in bufferList {
        if buf.mNumberChannels > 0 { return true }
    }
    return false
}

func getDeviceName(_ deviceID: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
    if status == noErr {
        return name as String
    }
    return "Unknown(\(deviceID))"
}

func isMicRunning(_ deviceID: AudioDeviceID) -> Bool {
    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
    return status == noErr && isRunning != 0
}

// MARK: - State tracking

/// Track which devices are currently running to emit aggregate MIC_ON/MIC_OFF
var activeDevices = Set<AudioDeviceID>()
let stateLock = NSLock()

func updateState(deviceID: AudioDeviceID) {
    let running = isMicRunning(deviceID)

    stateLock.lock()
    let wasMicOn = !activeDevices.isEmpty
    if running {
        activeDevices.insert(deviceID)
    } else {
        activeDevices.remove(deviceID)
    }
    let isMicOn = !activeDevices.isEmpty
    stateLock.unlock()

    if isMicOn && !wasMicOn {
        let name = getDeviceName(deviceID)
        fputs("mic-monitor: \(name) activated\n", stderr)
        print("MIC_ON")
        fflush(stdout)
    } else if !isMicOn && wasMicOn {
        let name = getDeviceName(deviceID)
        fputs("mic-monitor: \(name) deactivated, all mics off\n", stderr)
        print("MIC_OFF")
        fflush(stdout)
    }
}

// MARK: - Listener callback

let listenerCallback: AudioObjectPropertyListenerProc = {
    (objectID, numAddresses, addresses, clientData) -> OSStatus in
    updateState(deviceID: objectID)
    return noErr
}

// MARK: - Device list change callback

var monitoredDevices = Set<AudioDeviceID>()

func registerListeners(for devices: [AudioDeviceID]) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // Remove listeners from devices no longer present
    for old in monitoredDevices {
        if !devices.contains(old) {
            AudioObjectRemovePropertyListener(old, &address, listenerCallback, nil)
        }
    }

    // Add listeners to new devices
    for dev in devices {
        if !monitoredDevices.contains(dev) {
            let status = AudioObjectAddPropertyListener(dev, &address, listenerCallback, nil)
            if status == noErr {
                let name = getDeviceName(dev)
                fputs("mic-monitor: watching \(name) (\(dev))\n", stderr)
            }
        }
    }

    monitoredDevices = Set(devices)
}

let deviceListChangeCallback: AudioObjectPropertyListenerProc = {
    (objectID, numAddresses, addresses, clientData) -> OSStatus in
    let devices = getAllInputDevices()
    registerListeners(for: devices)
    fputs("mic-monitor: device list changed, now watching \(devices.count) input devices\n", stderr)
    return noErr
}

// MARK: - Main

// Register on all current input devices
let inputDevices = getAllInputDevices()
registerListeners(for: inputDevices)

// Listen for device list changes (plug/unplug)
var devicesChangedAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectAddPropertyListener(
    AudioObjectID(kAudioObjectSystemObject),
    &devicesChangedAddress,
    deviceListChangeCallback,
    nil
)

// Print initial state
stateLock.lock()
for dev in inputDevices {
    if isMicRunning(dev) {
        activeDevices.insert(dev)
    }
}
let initiallyOn = !activeDevices.isEmpty
stateLock.unlock()

print(initiallyOn ? "MIC_ON" : "MIC_OFF")
fflush(stdout)

fputs("mic-monitor: listening on \(inputDevices.count) input devices (Ctrl+C to stop)\n", stderr)

// Handle signals
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
signal(SIGPIPE, SIG_IGN)

RunLoop.main.run()
