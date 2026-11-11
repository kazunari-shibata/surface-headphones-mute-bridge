// SurfaceMuteBridge — Surface Headphones のミュート操作を検知して Teams に橋渡しするヘルパー（試作）
//
// 仕組み:
//   ミュート操作をすると、ヘッドフォンは「マイク音量 0」を Mac に 1 回通知する。
//   Mac 側は約 0.02 秒で音量を元に戻すため、ヘッドフォン自体はミュートにならない。
//   この一瞬の「音量 0」を 1 回の押下とみなし、Teams のミュートを切り替える。
//
// 使い方:
//   swiftc -O SurfaceMuteBridge.swift -o SurfaceMuteBridge
//   ./SurfaceMuteBridge                  # 検知のみ（押下を表示するだけ）
//   ./SurfaceMuteBridge --teams          # 押下ごとに、マイク使用中の通話アプリ（Teams / Zoom）へ
//                                        # ミュート切り替えのショートカットを送る
//   ./SurfaceMuteBridge --verbose        # 生の通知もすべて表示
//   ./SurfaceMuteBridge --device "Surface Headphones"

import AppKit
import ApplicationServices
import CoreAudio
import Foundation

// MARK: - 設定

var deviceNameFragment = "Surface Headphones"
var verbose = false
var sendToTeams = false
let teamsBundleID = "com.microsoft.teams2"
let debounceSeconds = 0.6      // 1 回の押下で届く通知のかたまりをまとめる時間
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

// MARK: - CoreAudio ヘルパー

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

/// 入力音量（0.0〜1.0）。要素 0（マスター）と 1 を順に試す。
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

// MARK: - 押下の判定

/// 音量通知の列から「ミュート操作が 1 回あった」を取り出す。
/// 通常: 0 → すぐ元の音量、というかたまりが 1 回の押下。
/// 例外: Mac が音量を戻さず 0 のまま残った場合は、次に 0 以外へ戻った時も 1 回の押下とする。
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

    /// 押下の少し後に呼び、音量が 0 のまま残っているかを記録する
    func settle(current v: Float?) {
        guard let v = v else { return }
        // 押下の瞬間の 0 をたまたま読んだだけ、という取り違えを避けるため 2 回連続で確認する
        zeroTicks = v <= zeroThreshold ? zeroTicks + 1 : 0
        if Date().timeIntervalSince(lastPress) > debounceSeconds {
            stuckAtZero = zeroTicks >= 2
        }
    }
    private var zeroTicks = 0

    func reset() { stuckAtZero = false; zeroTicks = 0 }
}

// MARK: - Teams への送信

/// 対応する通話アプリ。micPrefix はマイク使用中かどうかの判定に使う（補助プロセスも拾うため前方一致）。
struct CallApp {
    let name: String
    let bundleID: String      // キーの送り先
    let micPrefix: String
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let keyLabel: String
    var canSend: (() -> Bool)? = nil   // 送ってよい状況かの追加確認（ブラウザ用）
}

let chromeBundleID = "com.google.Chrome"

/// Chrome の最前面ウィンドウで表示中のタブが Meet かどうか。
/// Meet のショートカット Cmd+D は、他のタブでは「ブックマークに追加」になるため必ず確認する。
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
            log("  Chrome に問い合わせできませんでした: \(e[NSAppleScript.errorMessage] ?? e)")
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
var lastTarget: String?   // 直前に送ったアプリ（マイクを手放すアプリ向けの予備）

/// いまマイクを使っているプロセスのバンドル ID 一覧
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

/// アプリを前面に出さずに、ミュート切り替えのショートカットを送る
func sendToggle(to app: CallApp) {
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
        log("  \(app.name) が起動していないため送信しませんでした")
        return
    }
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: app.keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: app.keyCode, keyDown: false) else { return }
    down.flags = app.flags
    up.flags = app.flags
    down.postToPid(running.processIdentifier)
    up.postToPid(running.processIdentifier)
    log("  \(app.name) (pid \(running.processIdentifier)) に \(app.keyLabel) を送信")
}

/// マイクを使っている通話アプリへ送る。見つからなければ直前に送ったアプリへ送る。
func toggleCallMute() {
    let users = micUserBundleIDs()
    var targets = callApps.filter { app in users.contains { $0.hasPrefix(app.micPrefix) } }
    if targets.isEmpty, let last = lastTarget, let app = callApps.first(where: { $0.bundleID == last }) {
        log("  マイク使用中の対応アプリなし（使用中: \(users)）→ 直前の \(app.name) へ送ります")
        targets = [app]
    }
    if targets.isEmpty {
        log("  マイク使用中の対応アプリなし（使用中: \(users)）→ 送信しませんでした")
        return
    }
    // ブラウザは、Meet のタブが表示中のときだけ送る
    let allowed = targets.filter { app in
        guard let check = app.canSend else { return true }
        if check() { return true }
        log("  \(app.name): Meet のタブが表示中ではないため送信しませんでした")
        return false
    }
    for app in allowed { sendToggle(to: app) }
    if allowed.count == 1 { lastTarget = allowed[0].bundleID }
}

// MARK: - デバイス監視

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
        log("「\(deviceNameFragment)」の入力デバイスが見つかりません。接続を待ちます。")
        return
    }
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        guard let v = inputVolume(id) else { return }
        if verbose { log("  通知: 入力音量 = \(String(format: "%.2f", v))") }
        detector.volumeChanged(to: v)
    }
    let err = AudioObjectAddPropertyListenerBlock(id, &volumeAddr, queue, block)
    if err != noErr {
        log("音量の監視を登録できませんでした (OSStatus \(err))")
        return
    }
    watched = id
    volumeListener = block
    log("監視開始: \(deviceName(id)) 現在の入力音量 = \(inputVolume(id).map { String(format: "%.2f", $0) } ?? "不明")")
}

// 接続・切断に追従する
var devicesAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, queue) { _, _ in
    attachIfNeeded()
}

// MARK: - 起動

detector.onPress = {
    log("● ミュート操作を検知")
    if sendToTeams { toggleCallMute() }
}

if sendToTeams {
    // 他アプリへキーを送るにはアクセシビリティの許可が必要
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    log(trusted ? "アクセシビリティ: 許可済み" : "アクセシビリティ: 未許可（システム設定で許可するまで Teams には届きません）")
    if !trusted {
        // 許可されたら再起動なしで気づけるよう、定期的に確認する
        let axTimer = DispatchSource.makeTimerSource(queue: queue)
        axTimer.schedule(deadline: .now() + 2, repeating: 2)
        axTimer.setEventHandler {
            if AXIsProcessTrusted() {
                log("アクセシビリティ: 許可済み")
                axTimer.cancel()
            }
        }
        axTimer.resume()
    }
} else {
    log("検知のみのモードです（Teams へ送るには --teams）")
}

queue.async { attachIfNeeded() }

let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler { if let id = watched { detector.settle(current: inputVolume(id)) } }
timer.resume()

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
