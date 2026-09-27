# nits

A focused macOS menu-bar app for controlling external monitor brightness and volume,
and for making the Mac's own brightness/volume controls more precise.

Built because BetterDisplay Pro does far more than needed and MonitorControl has
degraded on recent macOS. *nit* is the unit of luminance.

## Status

**M4 built, pending permission** — menu-bar app with live sliders, plus media-key
interception, routing and an on-screen HUD. The key tap needs Accessibility
permission, which cannot be granted programmatically; the app prompts on first launch
and starts the tap as soon as it is granted, with no relaunch needed. Everything else
works without it. See `docs/hardware.md` for measured timings and findings.

Notable: this monitor exposes **no settable CoreAudio volume**, so volume has to go
over DDC VCP `0x62`. That also means macOS's own volume keys control nothing when the
monitor is the default output — which is precisely the gap this app closes.

## Why native Swift

External monitor brightness means DDC/CI over I2C, which has no public API on Apple
Silicon. It requires `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C` from
IOKit, callable only in-process. Electron or Python would need a Swift helper doing
all the real work anyway, plus a runtime tax on what is a menu-bar slider. Global
media-key interception (`CGEventTap`) is likewise native-only.

## Layout

```
Sources/NitsCore/          logic, no UI, testable without hardware
  PrivateAPI.swift         the ONLY file touching undeclared symbols
  DDC.swift                VCP framing + I2C transactions
  DisplayRegistry.swift    CGDisplay <-> IORegistry AV service matching
  Audio.swift              CoreAudio volume
  Coalescer.swift          latest-wins writes in front of slow hardware
  DisplayController.swift  per-display state, picks its backends by capability
  DisplayManager.swift     owns controllers, rebuilds on reconnect
Sources/nitsprobe/         diagnostics CLI
App/                       menu-bar app (AppKit shell, SwiftUI panel)
project.yml                Xcode project spec; the .xcodeproj is generated
```

`PrivateAPI.swift` resolves every undeclared symbol with `dlsym` at runtime rather
than binding at link time, so a symbol disappearing in a future macOS degrades one
feature instead of preventing launch. That single choke point is the direct answer to
why comparable tools break across OS upgrades.

## Usage

```sh
make test    # unit tests, no hardware needed
make probe   # hardware diagnostics, read-only
make run     # build and launch the menu-bar app
make stop    # quit it
make shots   # render the panel and HUD to PNGs for design review
```

`make app` and `make run` need `brew install xcodegen`; the `.xcodeproj` is generated
from `project.yml` rather than checked in, so build settings stay diffable.

Run `make probe` with the monitor attached to find out whether DDC works on your
cable, and whether the monitor's speakers expose a settable CoreAudio volume.

## Roadmap

- [x] **M0** core modules, probe CLI, unit tests
- [x] **M1** DDC confirmed against the panel — the approach works
- [x] **M2** volume: DDC `0x62` for this panel, CoreAudio where available
- [x] **M3** menu-bar UI with live sliders
- [x] **M4** event tap, custom HUD, key routing, fine steps *(needs Accessibility)*
- [ ] **M5** persistence, reconnect handling, launch at login

Deliberately out of scope for v1: sub-hardware-minimum software dimming,
input-source switching (VCP `0x60`), named presets. Seams are left for each.
