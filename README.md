# SurfaceMuteBridge

A small background helper for macOS that makes the mute gesture on Surface Headphones
toggle mute in your call app. It works even when the call app is not in the foreground.

| App | Shortcut sent | Condition |
|---|---|---|
| Microsoft Teams | Cmd+Shift+M | none |
| Zoom | Cmd+Shift+A | none |
| Google Meet (Chrome) | Cmd+D | only while the Meet tab is the visible tab of Chrome's front window |

## Why this is needed

Over Bluetooth, Surface Headphones expose only HFP / A2DP / AVRCP. They do not provide
the HID notifications that call apps use to sync mute state, so the headset's mute
gesture never reaches the app.

## How it works

1. On a mute gesture, the headset sends a single HFP "mic gain 0" event to the Mac.
2. The Mac's input volume drops to 0 for a moment (it is usually restored within about 0.02 s).
3. The helper watches the CoreAudio input volume and treats that 0 as one press.
4. It checks which app is using the microphone at that moment and sends that app its
   mute-toggle shortcut.

The helper only toggles on each press; it does not know whether you are currently muted.
Check the app's own mute indicator for the actual state.

## Install

Requires the Xcode Command Line Tools (`swiftc`).

```bash
./install.sh
```

This installs `~/Applications/SurfaceMuteBridge.app` and registers it to start at login.
The following permissions are needed on first install, and again after every rebuild:

- **Accessibility**: turn on SurfaceMuteBridge in System Settings → Privacy & Security →
  Accessibility. After a rebuild, turn it off and on again.
- **Control of Chrome** (only if you use Meet): approve the prompt that appears the first
  time you press mute during a Meet call.

## Troubleshooting

```bash
tail -20 ~/Library/Logs/SurfaceMuteBridge.log
```

- No "Mute gesture detected" line when you press: check that the headset is the active
  input device. The event is only sent while the microphone is in use, i.e. during a call.
- "Accessibility: not granted": redo the permission step above.
- "No supported app is using the microphone": an unsupported app is holding the microphone.

## Uninstall

```bash
./uninstall.sh
```

## Running it by hand

```bash
swiftc -O SurfaceMuteBridge.swift -o SurfaceMuteBridge
./SurfaceMuteBridge --verbose              # detect only, and print every raw notification
./SurfaceMuteBridge --teams                # detect and send to the call app
./SurfaceMuteBridge --device "part of name"  # watch a headset with a different name
```

## Limitations

- Tested only with Surface Headphones (firmware 16.1.0) on macOS 26.
- If an app changes its mute shortcut, update `callApps` in `SurfaceMuteBridge.swift`.
- Nothing is sent to Meet while another tab is showing in the same Chrome window,
  because Cmd+D would bookmark that page instead.

## License

[MIT](LICENSE)
