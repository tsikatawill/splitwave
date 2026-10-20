# Developing Splitwave

## Build and run

```sh
scripts/build-app.sh             # → build/Splitwave.app (menu-bar app, CLI inside)
open build/Splitwave.app
scripts/build-app.sh --install   # copy to /Applications and link the CLI into /usr/local/bin
UNIVERSAL=1 scripts/build-app.sh # Apple silicon + Intel, as releases ship
swift test                       # unit tests (renderer, planner, matching, store, meters, silence detector)
```

Requires Xcode 16 or later (Swift 5.9+) and macOS 14.2 or later.

### Keeping the audio permission across rebuilds

Ad-hoc signed builds look like a new app to macOS after each rebuild, so it asks for system audio
recording again. Run this once to create a "Splitwave Local" code-signing certificate in your login
keychain (macOS asks for your password to trust it); `build-app.sh` then signs with it automatically:

```sh
scripts/make-signing-cert.sh     # --remove deletes it again
```

### Using the CLI while developing

Use the CLI inside the app bundle (`build/Splitwave.app/Contents/MacOS/splitwave`), not the one in
`.build/`. macOS grants audio capture to the *responsible* app, and Terminal has no usage string for
it, so the CLI relaunches itself with responsibility disclaimed and macOS asks on Splitwave's behalf.

### Screenshots

`SplitwaveApp --snapshot <dir>` renders the popover and the first-run window to PNGs from live data.
`--snapshot docs --demo` renders the website screenshots (`docs/popover-light.png`,
`docs/popover-dark.png`) from made-up apps and devices. `swift scripts/make-icon.swift` redraws the
app icon and `docs/icon.png`.

## Releasing

```sh
scripts/release.sh 0.2.0         # builds, packages Splitwave.dmg, tags v0.2.0 and publishes the release
```

The website (`docs/`) is served by GitHub Pages from the `main` branch. Its download button points at
`releases/latest/download/Splitwave.dmg`, so it always gets the newest release.

## How it works

```
 Menu-bar UI ─┐                 ┌─ AudioMonitor: device list, default output, process list
 CLI ─────────┴─▶ RouteManager ◀┘
                     │ one chain per routed app
                     ▼
   process tap (muted) → private aggregate device [output device + tap] → IOProc (gain ramp) → output
```

- `AppCatalog` groups helper processes under the app responsible for them, so Chrome Helper and
  WebKit's GPU process count as Chrome and Safari.
- `RoutePlanner` (pure, tested) decides which chains should exist. A chain exists only while its app
  has audio processes and its device is connected. If the device disappears, the chain is removed
  and the app plays on the system default again. When the device comes back, the chain is rebuilt.
- `Renderer` runs on the real-time thread: it copies the tap channels into the output with a
  ~30 ms linear gain ramp and records peak levels for the meters. It makes no allocations, takes no
  locks and makes no Objective-C calls.
- When an app gains or loses helper processes (a new Chrome audio helper), the tap's process list
  is updated in place, so the sound doesn't drop out. Only a device change rebuilds a chain.
- macOS gives a tap without permission silence rather than an error. Splitwave reads the permission
  through TCC's preflight call, and as a fallback flags any route that stays silent for 4 s while its
  app is playing (`SilenceDetector`).
- The app and the CLI both log to `~/Library/Logs/Splitwave/splitwave.log` (the log button in the
  popover opens it): routes, fallbacks, retaps, failures and permission changes.
- `SplitwaveApp --snapshot <dir>` renders the popover and the first-run window to PNGs for layout checks.
- Routes are saved in `~/Library/Application Support/Splitwave/routes.json`. A distributed
  notification tells the running app to reload them.

## Manual test checklist

Before a release, run each of these once. Afterwards, check the log for
anything unexpected (`Could not route`, `No sound is reaching`, repeated `Rebuilding`).

- [ ] Spotify → AirPods while Zoom or Meet stays on the default output
- [ ] VLC or IINA → a TV (AirPlay) while Spotify stays on the Mac speakers
- [ ] Chrome → MacBook speakers at 30%; other apps keep their own volume
- [ ] AirPods disconnected mid-song: Spotify moves to the default output within a second, no silence
- [ ] AirPods reconnected: the route comes back without opening Splitwave
- [ ] Quit and reopen a routed app: the route applies again
- [ ] Log out and back in with launch at login on: saved routes apply

