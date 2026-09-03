# TailDesk

TailDesk is a minimal native Mac remote desktop with macOS and iPhone controllers. It uses
Tailscale for connectivity, ScreenCaptureKit for screen and system-audio
capture, VideoToolbox for hardware H.264, AVAudioEngine for playback, and
CGEvent for remote input.

## Build

```sh
./scripts/build-app.sh
open .build/TailDesk.app
```

Move `TailDesk.app` to `/Applications` before granting macOS privacy
permissions. Version 0.2.2 and later use a stable Apple Development signing
identity so permission grants survive subsequent rebuilds.

Run the same app on both Macs. On the controlled Mac:

1. Open TailDesk once. It registers itself to launch at login and becomes
   available automatically whenever the app is running.
2. Grant Screen Recording and Accessibility permissions when prompted, then
   restart TailDesk if macOS asks.

On the controller Mac:

1. Open the collapsible sidebar and select **控制端**.
2. Select an online Mac to load a read-only live preview.
3. Click the preview to enter control; exit control to disconnect and return
   to the device menu.

If the controlled Mac has multiple displays, choose a display from the tabs
above the preview or remote-control view. Pointer coordinates follow the
selected display. During control, move the pointer outside the remote screen
content (or to the top edge when it fills the window) to reveal the display
and exit controls; they stay hidden while unused.

## iPhone controller

The iPhone target requires the full Xcode app and iOS 17 or later:

1. Open `TailDesk.xcodeproj` in Xcode and select the **TailDesk-iOS** scheme.
2. Select your development team and a connected iPhone, then Run.
3. Install Tailscale on the iPhone and sign in to the same tailnet as the Macs.
4. On a Mac, open **连接 iPhone** in TailDesk. In the iPhone app, tap
   **扫描 Mac 二维码** and scan the code.
5. Select a Mac for a live preview, then tap the preview to start controlling.
   Multi-display Macs expose the same display selector on iPhone.

The QR code contains only the online Macs' MagicDNS names. It contains no IP
address, password, pairing key, or Tailscale credential. The iPhone supports
single-finger pointer movement, tap-to-click, double-tap-to-double-click, tap-then-hold dragging,
two-finger right-click and scrolling, remote text input, and clipboard text.
The connection stays active for background audio;
returning to the app requests a fresh video key frame so the picture resumes.

Mac controllers synchronize clipboard text and one file or folder of any size
in either direction. Files stream in 1 MB chunks, folders have no artificial
item-count limit, and the receiver keeps a disk-space safety reserve. Starting a
new file transfer invalidates the previous Finder clipboard immediately; the new
item becomes pasteable atomically when its transfer finishes. Received items are
stored under TailDesk's Application Support folder without changing their visible
file names. Transfers already in progress continue after returning to preview,
which shows their percentage and briefly confirms when an item is ready. A
sidebar action restores the latest item if another clipboard utility replaces it.
iPhone clipboard synchronization remains text-only.

The controlled Mac's stereo system audio plays on the controller. TailDesk
excludes its own playback from capture to avoid feedback; microphones are not
captured.

The host only accepts peers whose source address is in Tailscale's
`100.64.0.0/10` range and whose Tailscale user ID matches the host owner.
No IP address or separate pairing key is required.
Screen capture and video encoding start only after a controller connects and
stop when it disconnects; the idle listener does not continuously record.
Each Mac permits one incoming or outgoing session at a time. Busy peers are
rejected without interrupting the active controller, preventing control loops.

## Prototype limits

- One controller at a time; multiple host displays can be switched during a session
- Low-latency H.264 over TCP, up to 2560×1440 at 60 fps and about 16 Mbps
- Low-latency 48 kHz stereo Float32 PCM audio (about 3.1 Mbps)
- No microphone, symbolic links in clipboard folders, or adaptive bitrate yet
- Physical-keyboard shortcuts on iPhone are not mapped yet

Run the protocol framing check with:

```sh
.build/debug/TailDesk --self-check
```
