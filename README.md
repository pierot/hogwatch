# Hogwatch

A macOS menu bar watchdog for CPU hogs. It samples running processes, shows the heaviest ones in a dropdown, warns when one stays hot, and lets you kill it from the menu or straight from the notification.

Single Swift file, no dependencies, builds in seconds with the Xcode Command Line Tools.

## What it does

- Samples `ps` every 30 seconds and keeps a sliding window (default 15 minutes).
- The dropdown ranks the top 10 living processes by average CPU over that window, with app icons, pid, and a now column that refreshes every second while the menu is open.
- Click a row to kill the process (SIGTERM or SIGKILL, with confirmation).
- When a process stays above a threshold (default 90% of one core) for a sustained period (default 30 minutes), you get a notification with Kill, Force Kill, and Mute buttons.
- The menu bar icon turns orange as soon as anything crosses the icon threshold, before the notification fires. Hover it to see the culprit.
- Processes you never want alerts for (backup tools, indexers) can be muted by name.

## Install

### From Releases

Grab the zip from the [latest release](https://github.com/pierot/hogwatch/releases/latest) and unzip it. The binary is universal (Apple Silicon + Intel) but ad-hoc signed, not notarized, so macOS quarantines the download and refuses to open it. Clear the flag before first launch:

```sh
xattr -dr com.apple.quarantine Hogwatch.app
```

Alternatively, open the app once to dismiss the warning, then allow it under System Settings > Privacy & Security > Open Anyway. (Right-click > Open no longer bypasses Gatekeeper since macOS 15.)

### From source

```sh
./build.sh
open Hogwatch.app
```

`build.sh` produces a universal (arm64 + x86_64) ad-hoc-signed bundle, so the same app copies to another Mac. If you transfer it with AirDrop, clear the quarantine flag first: `xattr -dr com.apple.quarantine Hogwatch.app`.

To start it at login, add Hogwatch.app to System Settings > General > Login Items. Allow notifications when it asks.

Requires macOS 13 or later.

## Settings

Everything lives under the Settings item in the dropdown and persists in UserDefaults (`be.jackjoe.hogwatch`):

| Setting | Default | Meaning |
|---|---|---|
| Window | 15 min | How far back the avg column looks |
| Alert above | 90% | CPU threshold for notifications |
| Alert after | 30 min | How long a process must stay above the threshold |
| Orange above | 90% | Icon early-warning threshold, independent of the alert; can be off |
| Muted alerts | none | Per-name mute list, fed by the notification's Mute button |

## Semantics worth knowing

- CPU percentages come from `ps` pcpu: percent of one core, itself a decaying average over roughly the last minute, so spikes ramp over a few seconds rather than jumping.
- The avg column counts samples where a process was absent as 0%, so it effectively ranks by total CPU consumed over the window.
- Tracking is per pid. Browser and Electron helpers appear as separate rows, and alerts target the one runaway helper rather than the whole app.
- The sustained-load clock only resets after 3 consecutive below-threshold samples, so a process oscillating around the threshold still triggers.
- Sleep gaps reset sustained-load tracking; time asleep does not count toward the alert duration.
- After notifying, the same pid is quiet for an hour before it can re-alert.
- Killing from a stale notification re-checks that the pid still belongs to the same executable before sending a signal.

## Icon

`AppIcon.icns` is generated; to regenerate after design changes: `swift gen_icon.swift`.

## License

MIT, see [LICENSE](LICENSE).
