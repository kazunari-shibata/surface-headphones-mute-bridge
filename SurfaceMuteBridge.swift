// SurfaceMuteBridge — detects the mute gesture on Surface Headphones and forwards it to the call app.
//
// How it works:
//   On a mute gesture, the headset sends a single "mic gain 0" event to the Mac.
//   The Mac restores the volume within about 0.02 s, so the headset itself never stays muted.
//   That brief "volume 0" is treated as one press and toggles mute in the call app.
//
// Usage:
//   swiftc -O SurfaceMuteBridge.swift -o SurfaceMuteBridge
//   ./SurfaceMuteBridge                  # detect only (just prints each press)
//   ./SurfaceMuteBridge --teams          # on each press, send the mute-toggle shortcut to the
//                                        # call app using the microphone (Teams / Zoom / Meet)
//   ./SurfaceMuteBridge --verbose        # also print every raw notification
//   ./SurfaceMuteBridge --device "Surface Headphones"

import AppKit
import ApplicationServices
import CoreAudio
import Foundation

// MARK: - Configuration

var deviceNameFragment = "Surface Headphones"
var verbose = false
var sendToTeams = false
let teamsBundleID = "com.microsoft.teams2"
let debounceSeconds = 0.6      // window for grouping the burst of notifications one press produces
let zeroThreshold: Float = 0.05

do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--device": if let v = it.next() { deviceNameFragment = v }
        case "--teams": sendToTeams = true
        case "--verbose": verbose = true
        default: FileHandle.standardError.write("unknown option: \(a)\n".data(using: .utf8)!)
        }
    }
}
setvbuf(stdout, nil, _IOLBF, 0)

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
func log(_ s: String) { print("\(clock.string(from: Date())) \(s)") }

// MARK: - CoreAudio helpers

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
}

func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
}

/// Input volume (0.0–1.0). Tries element 0 (master), then element 1.
func inputVolume(_ id: AudioDeviceID) -> Float? {
    for element: UInt32 in [0, 1] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element)
        guard AudioObjectHasProperty(id, &addr) else { continue }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
    }
    return nil
}

// MARK: - Press detection

/// Turns the stream of volume notifications into "one mute gesture happened".
/// Normal case: a burst of 0 followed right away by the original volume is one press.
/// Exception: if the Mac leaves the volume at 0, the next change back to non-zero is also one press.
final class PressDetector {
    private var lastPress = Date.distantPast
    private var stuckAtZero = false
    var onPress: (() -> Void)?

    func volumeChanged(to v: Float) {
        let now = Date()
        if v <= zeroThreshold {
            if now.timeIntervalSince(lastPress) > debounceSeconds && !stuckAtZero {
                lastPress = now
                onPress?()
            }
        } else if stuckAtZero {
            stuckAtZero = false
            lastPress = now
            onPress?()
        }
    }

    /// Called periodically to record whether the volume has stayed at 0 after a press.
    func settle(current v: Float?) {
        guard let v = v else { return }
        // Require two consecutive readings so that catching the momentary 0 of a press
        // is not mistaken for the volume being stuck at 0.
        zeroTicks = v <= zeroThreshold ? zeroTicks + 1 : 0
        if Date().timeIntervalSince(lastPress) > debounceSeconds {
            stuckAtZero = zeroTicks >= 2
        }
    }
    private var zeroTicks = 0

    func reset() { stuckAtZero = false; zeroTicks = 0 }
}

// MARK: - Sending to call apps

/// A supported call app. micPrefix decides whether the app is using the microphone
/// (prefix match, so helper processes are picked up too).
struct CallApp {
    let name: String
    let bundleID: String      // where the key is sent
    let micPrefix: String
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let keyLabel: String
    var canSend: (() -> Bool)? = nil   // extra check that sending is safe right now (for browsers)
}

let chromeBundleID = "com.google.Chrome"

/// Whether the visible tab of Chrome's front window is Meet.
/// Meet's shortcut Cmd+D means "bookmark this page" on any other tab, so always check first.
func chromeFrontTabIsMeet() -> Bool {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty else { return false }
    var isMeet = false
    let run = {
        let src = """
        tell application id "\(chromeBundleID)"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
        """
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err {
            log("  Could not query Chrome: \(e[NSAppleScript.errorMessage] ?? e)")
        }
        isMeet = out?.stringValue?.hasPrefix("https://meet.google.com/") ?? false
    }
    if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
    return isMeet
}

let callApps = [
    CallApp(name: "Teams", bundleID: teamsBundleID, micPrefix: "com.microsoft.teams2",
            keyCode: 46, flags: [.maskCommand, .maskShift], keyLabel: "Cmd+Shift+M"),
    CallApp(name: "Zoom", bundleID: "us.zoom.xos", micPrefix: "us.zoom",
            keyCode: 0, flags: [.maskCommand, .maskShift], keyLabel: "Cmd+Shift+A"),
    CallApp(name: "Meet (Chrome)", bundleID: chromeBundleID, micPrefix: chromeBundleID,
            keyCode: 2, flags: [.maskCommand], keyLabel: "Cmd+D", canSend: chromeFrontTabIsMeet),
]
var lastTarget: String?   // the app last sent to (fallback for apps that release the microphone)

/// Bundle IDs of the processes currently using the microphone.
func micUserBundleIDs() -> [String] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr else { return [] }
    var result: [String] = []
    for o in objs {
        var running: UInt32 = 0
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(o, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }
        var bid: Unmanaged<CFString>?
        var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var baddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(o, &baddr, 0, nil, &bsize, &bid) == noErr, let b = bid {
            result.append(b.takeRetainedValue() as String)
        }
    }
    return result
}

/// Sends the mute-toggle shortcut to the app without bringing it to the front.
func sendToggle(to app: CallApp) {
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
        log("  \(app.name) is not running; nothing sent")
        return
    }
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: app.keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: app.keyCode, keyDown: false) else { return }
    down.flags = app.flags
    up.flags = app.flags
    down.postToPid(running.processIdentifier)
    up.postToPid(running.processIdentifier)
    log("  Sent \(app.keyLabel) to \(app.name) (pid \(running.processIdentifier))")
}

/// Sends to the call app that is using the microphone; if none is found, to the app last sent to.
func toggleCallMute() {
    let users = micUserBundleIDs()
    var targets = callApps.filter { app in users.contains { $0.hasPrefix(app.micPrefix) } }
    if targets.isEmpty, let last = lastTarget, let app = callApps.first(where: { $0.bundleID == last }) {
        log("  No supported app is using the microphone (in use by: \(users)); falling back to \(app.name)")
        targets = [app]
    }
    if targets.isEmpty {
        log("  No supported app is using the microphone (in use by: \(users)); nothing sent")
        return
    }
    // For browsers, send only while the Meet tab is the visible one.
    let allowed = targets.filter { app in
        guard let check = app.canSend else { return true }
        if check() { return true }
        log("  \(app.name): the Meet tab is not the visible tab; nothing sent")
        return false
    }
    for app in allowed { sendToggle(to: app) }
    if allowed.count == 1 { lastTarget = allowed[0].bundleID }
}

// MARK: - Device monitoring

let queue = DispatchQueue(label: "surface-mute-bridge")
let detector = PressDetector()
var watched: AudioDeviceID?
var volumeListener: AudioObjectPropertyListenerBlock?

var volumeAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyVolumeScalar,
    mScope: kAudioDevicePropertyScopeInput,
    mElement: kAudioObjectPropertyElementWildcard)

func detach() {
    if let id = watched, let block = volumeListener {
        AudioObjectRemovePropertyListenerBlock(id, &volumeAddr, queue, block)
    }
    watched = nil
    volumeListener = nil
}

func attachIfNeeded() {
    let target = allDevices().first {
        hasInputStreams($0) && deviceName($0).localizedCaseInsensitiveContains(deviceNameFragment)
    }
    if target == watched { return }
    detach()
    detector.reset()
    guard let id = target else {
        log("No input device matching \"\(deviceNameFragment)\" found; waiting for it to connect.")
        return
    }
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        guard let v = inputVolume(id) else { return }
        if verbose { log("  Notification: input volume = \(String(format: "%.2f", v))") }
        detector.volumeChanged(to: v)
    }
    let err = AudioObjectAddPropertyListenerBlock(id, &volumeAddr, queue, block)
    if err != noErr {
        log("Could not register the volume listener (OSStatus \(err))")
        return
    }
    watched = id
    volumeListener = block
    log("Watching: \(deviceName(id)), current input volume = \(inputVolume(id).map { String(format: "%.2f", $0) } ?? "unknown")")
}

// Follow connects and disconnects.
var devicesAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, queue) { _, _ in
    attachIfNeeded()
}

// MARK: - Startup

detector.onPress = {
    log("● Mute gesture detected")
    if sendToTeams { toggleCallMute() }
}

if sendToTeams {
    // Sending keys to another app requires the Accessibility permission.
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    log(trusted ? "Accessibility: granted" : "Accessibility: not granted (keys will not reach the call app until it is allowed in System Settings)")
    if !trusted {
        // Poll so that a later grant is noticed without a restart.
        let axTimer = DispatchSource.makeTimerSource(queue: queue)
        axTimer.schedule(deadline: .now() + 2, repeating: 2)
        axTimer.setEventHandler {
            if AXIsProcessTrusted() {
                log("Accessibility: granted")
                axTimer.cancel()
            }
        }
        axTimer.resume()
    }
} else {
    log("Detect-only mode (pass --teams to send to the call app)")
}

queue.async { attachIfNeeded() }

let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler { if let id = watched { detector.settle(current: inputVolume(id)) } }
timer.resume()

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
